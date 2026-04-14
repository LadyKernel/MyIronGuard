#!/usr/bin/env bash
# -------------------------------------------------------------------------
# Proyecto: Network Monitor - VPS
# Author: LadyKernel
# Repository: https://github.com/LadyKernel/MyIronGuard
# -------------------------------------------------------------------------
# Licencia: PolyForm Noncommercial License 1.0.0
# Copyright: (c) 2026 LadyKernel
# -------------------------------------------------------------------------
# Se permite el uso personal y educativo gratuito.
# El uso comercial o empresarial requiere autorización previa.
#
# Consultas de licencias o uso profesional: hola@lksys.es
# -------------------------------------------------------------------------

# --- 1. CONFIGURACIÓN DE RUTAS (HARDENING) ---
STAT="/usr/bin/stat"
CHMOD="/usr/bin/chmod"
VNSTAT="/usr/bin/vnstat"
AWK="/usr/bin/awk"
JQ="/usr/bin/jq"
DATE="/usr/bin/date"
CURL="/usr/bin/curl"

# --- 2. CARGA DE CONFIGURACIÓN ---
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$DIR/.env"

if [ -f "$ENV_FILE" ]; then
    # Hardening: Asegurar que el .env sea privado
    PERMS=$($STAT -c "%a" "$ENV_FILE" 2>/dev/null)
    if [ "$PERMS" != "600" ]; then
        $CHMOD 600 "$ENV_FILE" 2>/dev/null
    fi

    # Limpieza y carga de variables
    sed -i 's/\r//g' "$ENV_FILE"
    set -a; . "$ENV_FILE"; set +a
else
    echo "❌ Error: Archivo .env no encontrado en $DIR"
    exit 1
fi

# --- VERIFICACIÓN CRÍTICA ---
# Si la variable INTERFACES no está definida en el .env, el script se detiene.
if [ -z "$INTERFACES" ]; then
    echo "❌ Error: La variable INTERFACES no está definida en el archivo .env"
    exit 1
fi

# Configuración por defecto para cálculos (si no están en .env)
LIMITE_DIARIO=${LIMITE_DIARIO:-0.1}
LIMITE_MENSUAL=${LIMITE_MENSUAL:-900}
PRECIO_GB=${PRECIO_GB:-0}

# --- 3. FUNCIONES AUXILIARES ---
calc_gb() { $AWK -v b="$1" 'BEGIN {printf "%.2f", b/1073741824}'; }

formato_dinamico() {
    $AWK -v n="$1" 'BEGIN { if (n < 1 && n > 0) printf "%.2f MB", n*1024; else printf "%.2f GB", n; }'
}

# --- 4. BUCLE DE PROCESAMIENTO ---
for IFACE in $INTERFACES; do
    # Asignación dinámica de límites por interfaz
    IFACE_UPPER=$(echo "$IFACE" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    VAR_DIA="LIMITE_DIARIO_${IFACE_UPPER}"
    VAR_MES="LIMITE_MENSUAL_${IFACE_UPPER}"

    LIM_DIA=${!VAR_DIA:-$LIMITE_DIARIO}
    LIM_MES=${!VAR_MES:-$LIMITE_MENSUAL}

    STATE_DIA="$DIR/.alert_state_dia_${IFACE}.txt"
    STATE_MES="$DIR/.alert_state_mes_${IFACE}.txt"

    # Inicializar archivos de estado si no existen
    [ -f "$STATE_DIA" ] || echo "0" > "$STATE_DIA"
    [ -f "$STATE_MES" ] || echo "0" > "$STATE_MES"

    # Actualizar base de datos vnstat y capturar JSON
    $VNSTAT -u -i "$IFACE" > /dev/null 2>&1
    JSON_DATA=$($VNSTAT -i "$IFACE" --json 2>/dev/null)

    if [ -z "$JSON_DATA" ] || [ "$JSON_DATA" == "null" ]; then
        echo "⚠️  INTERFAZ: $IFACE - Sin datos. Verifica con: vnstat -i $IFACE --add"
        continue
    fi

    # Extracción de datos con JQ
    RX_D=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.day // .interfaces[0].traffic.days) | last | .rx // 0')
    TX_D=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.day // .interfaces[0].traffic.days) | last | .tx // 0')
    RX_M=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months) | last | .rx // 0')
    TX_M=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months) | last | .tx // 0')

    # Conversión a GB
    TOTAL_DIA_GB=$($AWK -v r=$(calc_gb "$RX_D") -v t=$(calc_gb "$TX_D") 'BEGIN {printf "%.2f", r+t}')
    TOTAL_MES_GB=$($AWK -v r=$(calc_gb "$RX_M") -v t=$(calc_gb "$TX_M") 'BEGIN {printf "%.2f", r+t}')

    # Lógica de Avisos (Comparación con último estado)
    ULTIMO_ALERTA_DIA=$(cat "$STATE_DIA")
    ULTIMO_ALERTA_MES=$(cat "$STATE_MES")

    AVISO_D=$($AWK -v t="$TOTAL_DIA_GB" -v l="$LIM_DIA" -v u="$ULTIMO_ALERTA_DIA" 'BEGIN {print (t > l && t >= u + 0.05) ? 1 : 0}')
    AVISO_M=$($AWK -v t="$TOTAL_MES_GB" -v l="$LIM_MES" -v u="$ULTIMO_ALERTA_MES" 'BEGIN {print (t > l && t >= u + 0.1) ? 1 : 0}')

    # --- SALIDA POR CONSOLA (Si se ejecuta manualmente) ---
    if [ -t 1 ]; then
        echo "======================================"
        echo "📊 MONITOR DE RED (Interfaz: $IFACE)"
        echo "======================================"
        echo "📅 Tráfico HOY: $TOTAL_DIA_GB GB (Límite: $LIM_DIA GB)"
        echo "🗓️ Tráfico MES: $TOTAL_MES_GB GB (Límite: $LIM_MES GB)"
        echo "🔔 Último aviso Telegram (Hoy): ${ULTIMO_ALERTA_DIA} GB"
        echo "🔔 Último aviso Telegram (Mes): ${ULTIMO_ALERTA_MES} GB"
        echo "--------------------------------------"
        [ "$AVISO_D" -eq 1 ] || [ "$AVISO_M" -eq 1 ] && echo "⚠️ LÍMITE SUPERADO" || echo "✅ Todo en orden."
        echo "======================================"
    fi

    # --- ENVÍO A TELEGRAM ---
    if [ "$AVISO_D" -eq 1 ] || [ "$AVISO_M" -eq 1 ]; then
        COSTE=$($AWK -v tx="$TOTAL_MES_GB" -v lim="$LIM_MES" -v p="$PRECIO_GB" 'BEGIN {if(tx>lim) printf "%.2f", (tx-lim)*p; else printf "0.00"}')

        MENSAJE="⚠️ *ALERTA VPS* ($IFACE)%0A"
        MENSAJE+="Hoy: *$(formato_dinamico "$TOTAL_DIA_GB")* / $LIM_DIA GB%0A"
        MENSAJE+="Mes: *$(formato_dinamico "$TOTAL_MES_GB")* / $LIM_MES GB%0A"
        MENSAJE+="Extra: *\$${COSTE}*"

        if [[ -n "${TOKEN}" && -n "${CHAT_ID}" ]]; then
            $CURL -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                -d "chat_id=$CHAT_ID&text=$MENSAJE&parse_mode=Markdown" > /dev/null

            # Guardar estado actual para evitar spam
            echo "$TOTAL_DIA_GB" > "$STATE_DIA"
            echo "$TOTAL_MES_GB" > "$STATE_MES"
        fi
    fi
done

