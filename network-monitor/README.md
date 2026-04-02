# 🚀 Network Monitor CLI

Una herramienta ligera y eficiente para monitorear el tráfico de red en servidores Linux, utilizando el motor de **vnStat** y con notificaciones automáticas integradas a **Telegram**. 

Ideal para administradores de sistemas que utilizan instancias en la nube (GCP, AWS, Azure) o VPS tradicionales, y desean evitar sorpresas en su facturación mensual controlando el *Egress traffic* o detectar picos anómalos de red.

## 📂 Arquitectura: ¿Qué versión elegir?

Debido a cómo diferentes proveedores manejan la virtualización de red, este repositorio se divide en dos versiones específicas para garantizar un 100% de fiabilidad:

* **📁 `/vps-estandar`**: Usa extracción vía JSON. Diseñado para proveedores clásicos (DigitalOcean, Hetzner, AWS, Linode) con interfaces estándar (`eth0`). Perfecto para usar como **Alarma Anti-DDoS** en servidores con tráfico ilimitado.
* **📁 `/gcloud`**: Usa extracción por patrones de texto crudo. Específicamente blindado para **Google Cloud Platform (GCP)** y sus interfaces (`ens4`). Ideal para controlar de forma estricta los costes de salida y el Free Tier.

---
---
## ✨ Características Principales

* **📊 Monitorización Dual:** Controla el tráfico diario y mensual de forma independiente desde una sola herramienta.
* **💰 Control de Costes:** Calcula automáticamente el gasto estimado basado en el tráfico de salida (Egress), perfecto para monitorizar el Free Tier de Google Cloud Platform (GCP) o AWS.
* **🛡️ Anti-Spam Inteligente:** Sistema de memoria que solo notifica si el tráfico sigue aumentando significativamente tras superar los límites establecidos.
* **🖥️ Multi-Instancia:** Muestra el *hostname* del servidor en la alerta, permitiendo identificar rápidamente qué VPS está consumiendo los recursos.
* **⚡ Bajo Consumo:** Diseñado para ejecutarse en segundo plano sin penalizar el rendimiento del sistema.
---

## 🛠️ Requisitos Previos

Antes de empezar, asegúrate de tener instalado **vnStat**, **jq** y **curl** en tu sistema:

### En Debian/Ubuntu
sudo apt update && sudo apt install vnstat jq curl -y

### En CentOS/RHEL
sudo yum install vnstat jq curl -y

---

## 🚀 Instalación y Configuración

1. **Clona el repositorio:**
git clone [https://github.com/LadyKernel/MyIronGuard.git](https://github.com/LadyKernel/MyIronGuard.git)
cd MyIronGuard/network-monitor/vps-estandar # o /gcloud

2. **Configura las variables de entorno:**
   Crea un archivo llamado `.env` en la raíz del proyecto. Este archivo contendrá tus credenciales privadas (asegúrate de que esté en tu `.gitignore`):

| Variable | Descripción | Ejemplo |
| :--- | :--- | :--- |
| **TOKEN** | Token de tu Bot de Telegram (vía @BotFather) | `12345:ABCDE...` |
| **CHAT_ID** | Tu ID de usuario, grupo o canal | `987654321` |
| **INTERFACE** | Interfaz de red a monitorizar | `ens4` o `eth0` |
| **LIMITE_DIARIO** | Umbral en GB para aviso diario | `1.5` |
| **LIMITE_MENSUAL** | Umbral en GB para aviso mensual | `100.0` |
| **PRECIO_GB** | Precio por GB de salida (Egress) | `0.12` |

3. **Dale permisos de ejecución:**
   chmod +x monitor.sh

---

## 🤖 Integración con Telegram

El script permite enviar reportes automáticos detallados. Para configurar el bot:
1. Habla con [@BotFather](https://t.me/botfather) en Telegram para crear tu bot y obtener el `TOKEN`.
2. Obtén tu `CHAT_ID` enviando un mensaje al bot y revisando: `https://api.telegram.org/bot<TU_TOKEN>/getUpdates`.
3. Activa la función de envío configurando las variables en el archivo `.env`.

---

## 📊 Uso y Automatización

### Ejecución Manual
Para realizar una comprobación instantánea:
./monitor.sh

### Automatización (Cron)
Para monitorizar el tráfico automáticamente (por ejemplo, cada hora), añade la siguiente línea a tu `crontab -e`:

0 * * * * /bin/bash /ruta/absoluta/a/tu/proyecto/monitor.sh

--- 

## 💡 Notas Técnicas (SysAdmin Tip)
Este script incluye una optimización crítica para entornos de producción:

Actualización en Tiempo Real: A diferencia de otros monitores que dependen del intervalo de actualización del demonio de vnStat, este script ejecuta **vnstat -u** antes de realizar la lectura. Esto garantiza que los datos de consumo y el coste estimado que recibes en Telegram estén actualizados al segundo exacto de la ejecución.

Cálculos Locale-Safe: Utiliza LC_NUMERIC=C y el motor awk internamente para garantizar que los cálculos matemáticos (como la multiplicación de decimales para el precio por GB) funcionen de manera robusta, independientemente del idioma base (locale) configurado en el servidor Linux.

---

## 🛠️ Solución de Problemas (Troubleshooting)
Si al ejecutar el script manualmente no recibes la alerta:

Revisa que no haya espacios extra en los valores de tu archivo .env.

Asegúrate de que los límites (LIMITE_DIARIO o LIMITE_MENSUAL) sean inferiores al tráfico actual para forzar la prueba.

Verifica que tu interfaz de red en el .env coincida con la de tu sistema (puedes verla ejecutando ip a o vnstat --iflist).

Si quieres forzar que el script olvide que ya te ha avisado, borra la memoria temporal: rm /tmp/ultimo_trafico_*.

---

## 📝 Ejemplo de Alerta

Cuando el script detecta un exceso de consumo, recibirás un mensaje como este:

> ⚠️ **ALERTA DE TRÁFICO VPS**
> -------------------------------
> 📅 **CONSUMO DE HOY:**
> 📥 Descarga: 0.85 GB
> 📤 Subida: 0.40 GB
> 📊 Total Día: **1.25 GB** / 1.0 GB
>
> 🗓️ **CONSUMO DEL MES (Marzo):**
> 📥 Descarga: 40.20 GB
> 📤 Subida: 15.30 GB
> ✨ Total Mes: **55.50 GB** / 100.0 GB
> 💰 Coste Estimado (TX): **$1.84**
> -------------------------------
> 🌐 Interfaz: ens4
> 🖥️ Hostname: google-cloud-vps

## ❓ Preguntas Frecuentes (FAQ)

**¿Cómo cambio la frecuencia de las alertas?**
El script se ejecuta según lo programado en tu **Crontab**. Si quieres que revise cada 5 minutos en lugar de cada hora, cambia el cron a: `*/5 * * * *`.

**¿El script consume muchos recursos?**
No. El script es Bash puro y solo se despierta, consulta a `vnstat` (que ya está corriendo como demonio), calcula y se cierra. El impacto en CPU/RAM es despreciable.

**¿Por qué no recibo el mensaje de Telegram?**
Asegúrate de que:
1. El `TOKEN` y `CHAT_ID` son correctos.
2. El servidor tiene acceso a internet (para hacer el `curl`).
3. Has superado los límites definidos en el `.env` respecto a la última lectura guardada.

**¿Funciona con varias interfaces de red?**
Sí, puedes clonar la carpeta para otra interfaz o simplemente cambiar la variable `INTERFACE` en el `.env`. El script generará archivos temporales separados para cada una.

**¿Es seguro poner mi Token en el `.env`?**
Sí, siempre y cuando **NO subas el archivo .env a GitHub**. El archivo `.gitignore` incluido en este repo está configurado para proteger tus credenciales.

---
## 📝 Licencia
Este proyecto está bajo la **Licencia MIT**. ¡Siéntete libre de usarlo y mejorarlo!
