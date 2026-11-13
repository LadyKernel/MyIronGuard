# 🧹 Dskwap Guardian CLI

Una herramienta ligera y segura para monitorear el almacenamiento raíz (`/`) y la memoria **SWAP** en servidores Linux (Ubuntu/Debian), con simulación previa de limpieza de logs y notificaciones automáticas a **Telegram** orientadas a SysAdmins.

Ideal para administradores de sistemas que gestionan instancias VPS con discos ajustados (8 GB – 20 GB) o entornos *Free Tier* en la nube (GCP, AWS, Azure), y desean recibir alertas preventivas con el detalle exacto de los archivos candidatos antes de ejecutar la limpieza controlada bajo demanda.

<p align="center">
  <img src="assets/banner-dskwap-guardian.jpg" alt="Dskwap Guardian CLI - MyIronGuard" width="100%">
</p>

---

## 📂 Arquitectura: Flujo Controlado en Dos Pasos

Diseñado en **Bash puro sin demonios residentes**, evita conflictos de API (`409 Conflict`) cuando compartes el mismo bot de Telegram entre múltiples servidores y elimina cualquier consumo permanente de RAM:

- **1️⃣ Fase de Auditoría y Alerta (`cron` / `--preview`):** El script inspecciona el uso de `/` y `SWAP`. Si supera el umbral configurado (80%), calcula sin tocar ningún archivo cuánto espacio se puede recuperar y envía un informe a Telegram con el desglose de ficheros y el comando exacto listo para copiar y ejecutar.
- **2️⃣ Fase de Ejecución Controlada (`--limpiar`):** El administrador revisa el aviso y lanza el comando en el servidor afectado. El script ejecuta la limpieza, guarda la auditoría completa en `/var/log/limpieza_disco.log` y envía una confirmación final por Telegram con los megabytes recuperados.

---

## ✨ Características Principales

- **🛡️ Control Total para SysAdmins (Zero Auto-Delete):** Nunca borra archivos sin intervención humana. Primero notifica qué se va a limpiar y entrega el comando listo para ejecutar.
- **📊 Monitorización Dual (Disco + SWAP):** Vigila de forma independiente el porcentaje de ocupación de la partición raíz (`/`) y la saturación de memoria `SWAP`.
- **🔇 Anti-Spam Inteligente:** En ejecución programada (`cron`), solo envía alertas cuando el disco o la SWAP superan el umbral crítico definido, evitando ruido innecesario cuando el servidor está sano.
- **🖥️ Multi-Servidor Friendly:** Al no utilizar *polling* (`getUpdates`) ni *webhooks*, puedes reutilizar el mismo token de Telegram en decenas de servidores simultáneamente sin conflictos.
- **📝 Auditoría Local Autorrotativa:** Guarda un historial detallado de cada limpieza en `/var/log/limpieza_disco.log`, recortándolo automáticamente a las últimas 500 líneas para proteger el espacio en disco.
- **⚡ Cero Dependencias Externas:** Construido íntegramente en Bash estándar y `curl`, sin Python, sin contenedores y con 0 MB de RAM en reposo.

---

## 🛠️ Requisitos Previos

El script utiliza herramientas nativas presentes en Ubuntu 24.04 LTS y Debian. Asegúrate de tener instalado **curl**:

### En Debian/Ubuntu
```bash
sudo apt update && sudo apt install curl -y

```

---

## 🚀 Instalación y Configuración

1. **Clona el repositorio:**
```bash
git clone https://github.com/LadyKernel/MyIronGuard.git
cd MyIronGuard/dskwap-guardian

```


2. **Configura las variables de entorno:**
Crea el archivo de credenciales protegido en `/etc/telegram_alerta.env` (asegúrate de nunca subir archivos `.env` a GitHub):
```bash
sudo nano /etc/telegram_alerta.env

```


| Variable | Descripción | Ejemplo |
| --- | --- | --- |
| **TELEGRAM_TOKEN** | Token de tu Bot de Telegram (vía @BotFather) | `123456789:ABCdefGHI...` |
| **CHAT_ID** | Tu ID de usuario, grupo o canal | `987654321` |


Restringe los permisos para que solo `root` pueda leer las credenciales:
```bash
sudo chmod 600 /etc/telegram_alerta.env
sudo chown root:root /etc/telegram_alerta.env

```


3. **Instala el script y dale permisos de ejecución:**
```bash
sudo cp dskwap-guardian.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/dskwap-guardian.sh

```


4. **(Opcional) Crea un alias rápido para SysAdmins:**
```bash
echo "alias limpiar-disco='sudo /usr/local/bin/dskwap-guardian.sh --limpiar'" | sudo tee -a /etc/bash.bashrc
source /etc/bash.bashrc

```



---

## 🤖 Integración con Telegram

El script permite enviar reportes preventivos y confirmaciones de limpieza. Para configurar el bot:

1. Habla con [@BotFather](https://t.me/botfather) en Telegram para crear tu bot y obtener el `TELEGRAM_TOKEN`.
2. Inicia una conversación con tu bot pulsando **Iniciar** y obtén tu `CHAT_ID` con [@userinfobot](https://t.me/userinfobot) o revisando `https://api.telegram.org/bot<TU_TOKEN>/getUpdates`.
3. Añade ambos valores en `/etc/telegram_alerta.env`.

---

## 📊 Modos de Uso y Automatización

| Comando | Comportamiento |
| --- | --- |
| `sudo /usr/local/bin/dskwap-guardian.sh` | **Modo Auditoría (Cron):** Revisa disco y SWAP. Solo envía alerta a Telegram si se supera el umbral del 80%, mostrando qué se puede limpiar y el comando a ejecutar. |
| `sudo /usr/local/bin/dskwap-guardian.sh --preview` | **Modo Simulación:** Fuerza el envío a Telegram del informe de espacio recuperable aunque el disco esté por debajo del 80%. |
| `sudo /usr/local/bin/dskwap-guardian.sh --limpiar` | **Modo Ejecución:** Borra logs rotados antiguos, vacía logs activos >50MB, limpia `journald` y caché `apt`, registra en `/var/log/limpieza_disco.log` y notifica el resultado en Telegram. |

### Automatización (Cron)

Para auditar el servidor automáticamente cada 6 horas, añade esta línea a tu `sudo crontab -e`:

```cron
0 */6 * * * /usr/local/bin/dskwap-guardian.sh

```

---

## 💡 Notas Técnicas (SysAdmin Tip)

Este script incluye optimizaciones críticas para entornos de producción con poco almacenamiento:

* **Truncado Seguro de Logs Activos:** Los archivos `.log` activos mayores a `50 MB` no se eliminan con `rm`, sino que se vacían mediante `truncate -s 0`. Esto evita romper los descriptores de archivo (*file descriptors*) de demonios activos como Nginx, Docker o servicios del sistema.
* **Límite Permanente en Systemd Journald:** Se recomienda fijar `SystemMaxUse=100M` en `/etc/systemd/journald.conf` para evitar que los registros binarios del kernel ocupen por defecto hasta el 10% del disco.
* **Cálculos Locale-Safe y UTF-8 Puro:** Ejecuta `LC_ALL=C free -m` para garantizar la lectura de memoria SWAP independientemente del idioma del sistema operativo y utiliza `--data-urlencode` en `curl` para enviar emojis y acentos sin corrupción de caracteres.

---

## 🛠️ Solución de Problemas (Troubleshooting)

Si al ejecutar el script manualmente no recibes la alerta:

* **El disco está por debajo del 80%:** En modo por defecto (`cron`), el script guarda silencio si disco y SWAP están sanos. Ejecuta `sudo /usr/local/bin/dskwap-guardian.sh --preview` para forzar un envío de prueba.
* **Revisa el archivo `.env`:** Verifica que no haya espacios alrededor del signo `=` en `/etc/telegram_alerta.env`.
* **Consulta el historial local:** Revisa las limpiezas realizadas con `cat /var/log/limpieza_disco.log`.

---

## 📝 Ejemplo de Flujo de Alertas

### 1. Alerta Preventiva (Enviada automáticamente por Cron al superar el umbral)

```text
⚠️ ALERTA DE ESPACIO Y LOGS

🖥 Servidor: $host
📊 Estado: Disco 82% (1.5G/8.7G) | SWAP 12%

🚨 Crítico: Disco por encima del 80%

📋 Espacio recuperable (~1545 MB estimados):
• Journald: ~962 MB por encima del límite
• Logs rotados (62 archivos / ~15 MB):
   - /var/log/dpkg.log.3.gz
   - /var/log/ufw.log.1
   - /var/log/auth.log.4.gz
   ...y 59 más.
• Caché APT: ~405 MB

👉 Para ejecutar la limpieza en este servidor:
sudo /usr/local/bin/dskwap-guardian.sh --limpiar

```

### 2. Confirmación tras ejecutar `--limpiar`

```text
✅ LIMPIEZA COMPLETADA EN mypekeironguard

🧹 Espacio recuperado: 1545 MB
💾 Disco actual: 21% ocupado (38G libres)

📋 Resumen:
• Journald: Vacuuming done, freed 962.0M of archived journals
• Logs rotados borrados: 62 archivos
• Caché APT: 405 MB liberados

📝 Detalle guardado en /var/log/limpieza_disco.log

```

---

## ❓ Preguntas Frecuentes (FAQ)

**¿Puedo usar este script en varios servidores con el mismo bot de Telegram?**
Sí. Al funcionar únicamente con peticiones salientes (`sendMessage`) sin escuchar actualizaciones (`getUpdates`), puedes desplegarlo en todos tus nodos sin conflictos.

**¿Cómo cambio el umbral del 80% o los días de retención de logs?**
Edita las variables `UMBRAL_DISCO`, `UMBRAL_SWAP` y `DIAS_LOGS` en la cabecera de `/usr/local/bin/dskwap-guardian.sh`.

**¿El script puede borrarse su propio archivo de log?**
No. El comando `find` excluye explícitamente `/var/log/limpieza_disco.log` mediante `! -path` para preservar siempre la auditoría.

---

## Si este script te ha ahorrado tiempo en el mantenimiento de tus servidores, considera darle una ⭐ para que otros puedan encontrarlo.

---

## 🛡️ Licencia y Uso Comercial

Este proyecto se distribuye bajo la licencia **PolyForm Noncommercial License 1.0.0**.

* **Uso Comunitario:** Eres libre de usar, modificar y mejorar esta herramienta para tus laboratorios personales y proyectos educativos.
* **Uso Profesional:** El uso en entornos corporativos, organizaciones con ánimo de lucro o fines comerciales requiere una autorización específica.

> [!IMPORTANT]
> El uso de este software en entornos de producción empresarial sin la licencia correspondiente infringe los términos de uso. Para entender todos los términos legales, consulta el archivo `LICENSE`.

**¿Necesitas una licencia comercial o soporte para su integración?**
📩 **Contacto:** [hola@lksys.es](mailto:hola@lksys.es)
