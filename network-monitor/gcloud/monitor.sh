#!/usr/bin/env bash
# -------------------------------------------------------------------------
# Proyecto: Network Monitor - GCLOUD
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

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- 1. RUTAS ---
CURL="/usr/bin/curl"; JQ="/usr/bin/jq"; AWK="/usr/bin/awk"; VNSTAT="/usr/bin/vnstat"
DATE="/usr/bin/date"; HOSTNAME_CMD="/usr/bin/hostname"; CHMOD="/usr/bin/chmod"
STAT="/usr/bin/stat"; SED="/usr/bin/sed"; REPO_URL="https://github.com/LadyKernel/MyIronGuard"
export LC_ALL=C

# --- 2. CONFIGURACIÓN ---
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$DIR/.env"

if [ -f "$ENV_FILE" ]; then
    PERMS=$($STAT -c "%a" "$ENV_FILE"); [ "$PERMS" -ne 600 ] && $CHMOD 600 "$ENV_FILE"
    $SED -i 's/\r//g' "$ENV_FILE"; set -a; . "$ENV_FILE"; set +a
else
    echo "❌ Error: .env no encontrado." >&2; exit 1
fi

# Variables base (si no están en .env, usan estos valores)
INTERFACE=${INTERFACE:-"ens6"}
LIMITE_DIARIO=${LIMITE_DIARIO:-0.1}
LIMITE_MENSUAL=${LIMITE_MENSUAL:-900}
PRECIO_GB=${PRECIO_GB:-0}
TOKEN=${TOKEN:-""}
CHAT_ID=${CHAT_ID:-""}
UMBRAL_ALERTA=${UMBRAL_ALERTA:-0.9}
STEP_D=${STEP_D:-0.05}
STEP_M=${STEP_M:-0.1}

STATE_DIA="$DIR/.alert_state_dia_${INTERFACE}.txt"
STATE_MES="$DIR/.alert_state_mes_${INTERFACE}.txt"
CONTROL_MES="$DIR/.last_month_${INTERFACE}.txt"

# --- 3. LÓGICA DE RESET MENSUAL ---
MES_ACTUAL=$($DATE +%m)
[ -f "$CONTROL_MES" ] || echo "$MES_ACTUAL" > "$CONTROL_MES"
[ -f "$STATE_DIA" ] || echo "0" > "$STATE_DIA"; [ -f "$STATE_MES" ] || echo "0" > "$STATE_MES"

if [ "$MES_ACTUAL" != "$(cat "$CONTROL_MES")" ]; then
    echo "0" > "$STATE_DIA"; echo "0" > "$STATE_MES"; echo "$MES_ACTUAL" > "$CONTROL_MES"
fi

# --- 4. CAPTURA Y PROCESAMIENTO ---
$VNSTAT -u -i "$INTERFACE" > /dev/null 2>&1 || true
JSON_DATA=$($VNSTAT -i "$INTERFACE" --json 2>/dev/null)
[ -z "$JSON_DATA" ] || [ "$JSON_DATA" == "null" ] && exit 1

DIVISOR=1073741824
calc_gb() { $AWK "BEGIN {printf \"%.2f\", $1 / $DIVISOR}"; }

RX_D=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.day // .interfaces[0].traffic.days) | last | .rx // 0')
TX_D=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.day // .interfaces[0].traffic.days) | last | .tx // 0')
RX_M=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months) | last | .rx // 0')
TX_M=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months) | last | .tx // 0')

TOTAL_DIA_GB=$(awk "BEGIN {printf \"%.2f\", $(calc_gb "$RX_D") + $(calc_gb "$TX_D")}")
TOTAL_MES_GB=$(awk "BEGIN {printf \"%.2f\", $(calc_gb "$RX_M") + $(calc_gb "$TX_M")}")

# --- 5. LÓGICA DE ESTADO ---
PORC_MES=$(awk -v t="$TOTAL_MES_GB" -v l="$LIMITE_MENSUAL" 'BEGIN {printf "%.1f", (t/l)*100}')
if (( $(echo "$PORC_MES >= 90" | bc -l) )); then ESTADO="CRITICAL"; ICONO="🔴"; ES_CRITICO=1
elif (( $(echo "$PORC_MES >= 70" | bc -l) )); then ESTADO="WARNING"; ICONO="🟡"; ES_CRITICO=0
else ESTADO="NORMAL"; ICONO="🟢"; ES_CRITICO=0; fi

# --- 6. SALIDA VISUAL (CONSOLA) ---
if [ -t 1 ]; then
    echo "======================================"
    echo "📊 MONITOR DE RED (Interfaz: $INTERFACE)"
    echo "======================================"
    echo "📅 Tráfico HOY: $TOTAL_DIA_GB GB"
    echo "🗓️  Tráfico MES: $TOTAL_MES_GB GB / $LIMITE_MENSUAL GB ($PORC_MES%)"
    echo -e "🚦 Estado: $ICONO $ESTADO"
    [ "$ES_CRITICO" -eq 1 ] && echo -e "⚠️ ¡Alerta! Repo: $REPO_URL"
    echo "======================================"
    echo "🛡️   MyIronGuard v2.0 (PolyForm NC)"
    echo "🏢 Empresa: hola@lksys.es"
    echo "⭐ Si te gusta el script, apóyame con una estrella en:"
    echo -e "🔗 \e[1;34mRepo: $REPO_URL\e[0m"
    echo "======================================"
fi

# --- 7. LÓGICA DE ALERTAS ---
ULTIMO_ALERTA_DIA=$(cat "$STATE_DIA"); ULTIMO_ALERTA_MES=$(cat "$STATE_MES")
AVISO_DIA=$(awk -v t="$TOTAL_DIA_GB" -v l="$LIMITE_DIARIO" -v u="$UMBRAL_ALERTA" -v last="$ULTIMO_ALERTA_DIA" -v s="$STEP_D" 'BEGIN { inc=(t>=last+s); cross_u=(t>=l*u && last<l*u); print (inc || cross_u) ? 1 : 0 }')
AVISO_MES=$(awk -v t="$TOTAL_MES_GB" -v l="$LIMITE_MENSUAL" -v u="$UMBRAL_ALERTA" -v last="$ULTIMO_ALERTA_MES" -v s="$STEP_M" 'BEGIN { inc=(t>=last+s); cross_u=(t>=l*u && last<l*u); print (inc || cross_u) ? 1 : 0 }')

# --- 8. TELEGRAM ---
if [ "$AVISO_DIA" -eq 1 ] || [ "$AVISO_MES" -eq 1 ]; then
    COSTE=$(awk -v tx="$TOTAL_MES_GB" -v lim="$LIMITE_MENSUAL" -v p="$PRECIO_GB" 'BEGIN { printf "%.2f", (tx > lim) ? (tx - lim) * p : 0.00 }')
    formato_dinamico() { awk -v n="$1" 'BEGIN { if (n < 1 && n > 0) printf "%.2f MB", n * 1024; else printf "%.2f GB", n; }'; }

    # Lógica de títulos y footer (solo footer si ES_CRITICO es 1)
    TITULO=$([ "$ES_CRITICO" -eq 1 ] && echo "⚠️ *ALERTA VPS CRÍTICA (GCLOUD)*" || echo "ℹ️ *INFORME VPS (GCLOUD)*")
    FOOTER=$([ "$ES_CRITICO" -eq 1 ] && echo -e "\n⭐ *¡Apoya el proyecto con una estrella!*\n$REPO_URL" || echo "")

    MENSAJE=$(printf "%s\n\n📆 *Hoy*\n┣ 📊 Total Día: *%s* / %s GB\n\n🗓️ *Consumo del mes (%s):*\n┣ 📦 Total Mes: *%s* / %s GB (%s%%)\n┣ 💰 Coste Extra: *\$%s*\n┗ 🚦 Estado: %s *%s*%s" \
    "$TITULO" "$(formato_dinamico "$TOTAL_DIA_GB")" "$LIMITE_DIARIO" "$($DATE +%B)" \
    "$(formato_dinamico "$TOTAL_MES_GB")" "$LIMITE_MENSUAL" "$PORC_MES" "$COSTE" "$ICONO" "$ESTADO" "$FOOTER")

    if [ -n "$TOKEN" ] && [ -n "$CHAT_ID" ]; then
        TELEGRAM_MESSAGE=$($JQ -n --arg cid "$CHAT_ID" --arg txt "$MENSAJE" '{chat_id: $cid, text: $txt, parse_mode: "Markdown"}')
        $CURL -s -m 10 -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "$TELEGRAM_MESSAGE" > /dev/null
        echo "$TOTAL_DIA_GB" > "$STATE_DIA"; echo "$TOTAL_MES_GB" > "$STATE_MES"
    fi
fi
