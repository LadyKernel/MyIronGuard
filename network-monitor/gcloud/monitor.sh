#!/usr/bin/env bash
# -------------------------------------------------------------------------
# Proyecto:  Network Monitor - GCLOUD
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

# --- 1. SEGURIDAD DE EJECUCIÓN (Fail-safe) ---
set -euo pipefail
# Restringimos el PATH para evitar Path Hijacking
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- 2. RUTAS ABSOLUTAS DE HERRAMIENTAS (Anti-suplantación) ---
CURL="/usr/bin/curl"
JQ="/usr/bin/jq"
AWK="/usr/bin/awk"
VNSTAT="/usr/bin/vnstat"
DATE="/usr/bin/date"
HOSTNAME_CMD="/usr/bin/hostname"
CHMOD="/usr/bin/chmod"
STAT="/usr/bin/stat"
SED="/usr/bin/sed"
GREP="/usr/bin/grep"

# Aseguramos formato numérico internacional
export LC_ALL=C

# --- 3. CARGA SEGURA DE CONFIGURACIÓN ---
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$DIR/.env"

if [ -f "$ENV_FILE" ]; then
    # Hardening: El .env solo debe ser legible por el dueño (600)
    PERMS=$($STAT -c "%a" "$ENV_FILE")
    [ "$PERMS" -ne 600 ] && $CHMOD 600 "$ENV_FILE"

    # Limpiamos retornos de carro y cargamos variables
    $SED -i 's/\r//g' "$ENV_FILE"
    # Cargamos variables evitando que fallen si hay líneas vacías o comentarios
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
else
    echo "❌ Error: Archivo .env no encontrado en $DIR" >&2
    exit 1
fi

# Validaciones de variables críticas
INTERFACE=${INTERFACE:-"ens6"}
LIMITE_DIARIO=${LIMITE_DIARIO:-0.1}
LIMITE_MENSUAL=${LIMITE_MENSUAL:-900}
PRECIO_GB=${PRECIO_GB:-0}
TOKEN=${TOKEN:-""}
CHAT_ID=${CHAT_ID:-""}

STATE_DIA="$DIR/.alert_state_dia_${INTERFACE}.txt"
STATE_MES="$DIR/.alert_state_mes_${INTERFACE}.txt"

# --- 4. VERIFICACIÓN DE DEPENDENCIAS ---
for cmd in "$CURL" "$JQ" "$AWK" "$VNSTAT"; do
    if [ ! -x "$cmd" ]; then
        echo "❌ Error: No se encuentra o no es ejecutable: $cmd" >&2
        exit 1
    fi
done

# --- 5. CAPTURA Y PROCESAMIENTO ---
# Actualizamos vnstat
$VNSTAT -u -i "$INTERFACE" > /dev/null 2>&1 || true
JSON_DATA=$($VNSTAT -i "$INTERFACE" --json 2>/dev/null)

if [ -z "$JSON_DATA" ] || [ "$JSON_DATA" == "null" ]; then
    echo "❌ Error: Datos de vnstat vacíos para $INTERFACE" >&2
    exit 1
fi

DIVISOR=1073741824

# Extracción de bytes con JQ
RX_D=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.day // .interfaces[0].traffic.days) | last | .rx // 0')
TX_D=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.day // .interfaces[0].traffic.days) | last | .tx // 0')
RX_M=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months) | last | .rx // 0')
TX_M=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months) | last | .tx // 0')

# Cálculos con AWK
calc_gb() { $AWK "BEGIN {printf \"%.2f\", $1 / $DIVISOR}"; }

RX_DIA_GB=$(calc_gb "$RX_D")
TX_DIA_GB=$(calc_gb "$TX_D")
TOTAL_DIA_GB=$(awk "BEGIN {printf \"%.2f\", $RX_DIA_GB + $TX_DIA_GB}")

RX_MES_GB=$(calc_gb "$RX_M")
TX_MES_GB=$(calc_gb "$TX_M")
TOTAL_MES_GB=$(awk "BEGIN {printf \"%.2f\", $RX_MES_GB + $TX_MES_GB}")

# --- 6. LÓGICA DE ALERTAS ---
[ -f "$STATE_DIA" ] || echo "0" > "$STATE_DIA"
[ -f "$STATE_MES" ] || echo "0" > "$STATE_MES"
$CHMOD 600 "$STATE_DIA" "$STATE_MES"

ULTIMO_ALERTA_DIA=$(cat "$STATE_DIA")
ULTIMO_ALERTA_MES=$(cat "$STATE_MES")

AVISO_DIA=$(awk -v t="$TOTAL_DIA_GB" -v l="$LIMITE_DIARIO" -v u="$ULTIMO_ALERTA_DIA" 'BEGIN {print (t > l && t >= u + 0.05) ? 1 : 0}')
AVISO_MES=$(awk -v t="$TOTAL_MES_GB" -v l="$LIMITE_MENSUAL" -v u="$ULTIMO_ALERTA_MES" 'BEGIN {print (t > l && t >= u + 0.1) ? 1 : 0}')

# --- 7. SALIDA VISUAL (Modo Interactivo) ---
if [ -t 1 ]; then
    echo "======================================"
    echo "📊 MONITOR DE RED (Interfaz: $INTERFACE))"
    echo "======================================"
    echo "📅 Tráfico HOY: $TOTAL_DIA_GB GB (Límite: $LIMITE_DIARIO GB)"
    echo "🗓️ Tráfico MES: $TOTAL_MES_GB GB (Límite: $LIMITE_MENSUAL GB)"
    echo "🔔 Último aviso Telegram (Hoy): ${ULTIMO_ALERTA_DIA} GB"
    echo "🔔 Último aviso Telegram (Mes): ${ULTIMO_ALERTA_MES} GB"
    echo "--------------------------------------"
    if [ "$AVISO_DIA" -eq 1 ] || [ "$AVISO_MES" -eq 1 ]; then
        echo "⚠️ LÍMITE SUPERADO - Preparando Telegram..."
    else
        echo "✅ Estado: Bajo control."
    fi
    echo "======================================"
fi

# --- 8. ENVÍO A TELEGRAM ---
if [ "$AVISO_DIA" -eq 1 ] || [ "$AVISO_MES" -eq 1 ]; then

    COSTE_ESTIMADO=$(awk -v tx="$TOTAL_MES_GB" -v lim="$LIMITE_MENSUAL" -v p="$PRECIO_GB" \
        'BEGIN { if (tx > lim) printf "%.2f", (tx - lim) * p; else printf "0.00"; }')

    formato_dinamico() {
        local val="$1"
        awk -v n="$val" 'BEGIN { if (n < 1 && n > 0) printf "%.2f MB", n * 1024; else printf "%.2f GB", n; }'
    }

    # Título fijo por seguridad y claridad
    TITULO="⚠️ *ALERTA DE TRÁFICO GCLOUD*"

    MENSAJE="$TITULO
-------------------------------
📅 *CONSUMO DE HOY:*
📥 Descarga: $(formato_dinamico "$RX_DIA_GB")
📤 Subida: $(formato_dinamico "$TX_DIA_GB")
📊 Total Día: *$(formato_dinamico "$TOTAL_DIA_GB")* / $LIMITE_DIARIO GB

🗓️ *CONSUMO DEL MES ($($DATE +%B)):*
📥 Descarga: $(formato_dinamico "$RX_MES_GB")
📤 Subida: $(formato_dinamico "$TX_MES_GB")
✨ Total Mes: *$(formato_dinamico "$TOTAL_MES_GB")* / $LIMITE_MENSUAL GB
💰 Coste Extra: *\$${COSTE_ESTIMADO}*
-------------------------------
🌐 Interfaz: $INTERFACE
🖥️ Hostname: $($HOSTNAME_CMD)"

    if [ -n "$TOKEN" ] && [ -n "$CHAT_ID" ]; then
        # Generamos el JSON con JQ para neutralizar cualquier inyección en el mensaje
        PAYLOAD=$($JQ -n --arg cid "$CHAT_ID" --arg txt "$MENSAJE" '{chat_id: $cid, text: $txt, parse_mode: "Markdown"}')

        RESPUESTA=$($CURL -s -m 10 -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD")

        if echo "$RESPUESTA" | $GREP -q '"ok":true'; then
            echo "$TOTAL_DIA_GB" > "$STATE_DIA"
            echo "$TOTAL_MES_GB" > "$STATE_MES"
        else
            echo "❌ Error enviando a Telegram: $RESPUESTA" >&2
        fi
    fi
fi

