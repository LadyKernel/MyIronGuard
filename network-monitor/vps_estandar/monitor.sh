#!/bin/bash

# --- 1. CARGA DE CONFIGURACIÓN ---
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$DIR/.env" ]; then
    source "$DIR/.env"
else
    echo "❌ Error: Archivo .env no encontrado."
    exit 1
fi

# Valores por defecto de seguridad
LIMITE_DIARIO=${LIMITE_DIARIO:-0}
LIMITE_MENSUAL=${LIMITE_MENSUAL:-0}
PRECIO_GB=${PRECIO_GB:-0}
INTERFACE=${INTERFACE:-"eth0"}

TEMP_DIA="/tmp/ultimo_trafico_dia_$INTERFACE.txt"
TEMP_MES="/tmp/ultimo_trafico_mes_$INTERFACE.txt"

# --- 2. CAPTURA DE DATOS ---
# Forzamos actualización y capturamos JSON
vnstat -u -i "$INTERFACE" > /dev/null 2>&1
JSON_DATA=$(vnstat -i "$INTERFACE" --json 2>/dev/null)

# Función para extraer datos de forma segura
get_val() {
    local val=$(echo "$JSON_DATA" | jq -r "$1" 2>/dev/null)
    [[ "$val" == "null" || -z "$val" ]] && echo 0 || echo "$val"
}

# Extraemos RX y TX (Día y Mes) con la nueva función segura
RX_DIA_KIB=$(get_val '.interfaces[0].traffic.day[0].rx')
TX_DIA_KIB=$(get_val '.interfaces[0].traffic.day[0].tx')
RX_MES_KIB=$(get_val '.interfaces[0].traffic.month[0].rx')
TX_MES_KIB=$(get_val '.interfaces[0].traffic.month[0].tx')

# --- 3. CÁLCULOS CON AWK (Protegidos contra valores vacíos) ---
TOTAL_DIA_GB=$(awk "BEGIN {printf \"%.2f\", ($RX_DIA_KIB + $TX_DIA_KIB) / 1048576}")
TOTAL_MES_GB=$(awk "BEGIN {printf \"%.2f\", ($RX_MES_KIB + $TX_MES_KIB) / 1048576}")
RX_DIA_GB=$(awk "BEGIN {printf \"%.2f\", $RX_DIA_KIB / 1048576}")
TX_DIA_GB=$(awk "BEGIN {printf \"%.2f\", $TX_DIA_KIB / 1048576}")
RX_MES_GB=$(awk "BEGIN {printf \"%.2f\", $RX_MES_KIB / 1048576}")
TX_MES_GB=$(awk "BEGIN {printf \"%.2f\", $TX_MES_KIB / 1048576}")

# --- 4. LÓGICA DE ALERTAS ---
[ -f "$TEMP_DIA" ] || echo "0" > "$TEMP_DIA"
[ -f "$TEMP_MES" ] || echo "0" > "$TEMP_MES"

ULTIMO_DIA=$(cat "$TEMP_DIA")
ULTIMO_MES=$(cat "$TEMP_MES")

# Comparación numérica segura
AVISO_DIA=$(awk "BEGIN {print ($TOTAL_DIA_GB > $LIMITE_DIARIO && $TOTAL_DIA_GB >= $ULTIMO_DIA + 0.1) ? 1 : 0}")
AVISO_MES=$(awk "BEGIN {print ($TOTAL_MES_GB > $LIMITE_MENSUAL && $TOTAL_MES_GB >= $ULTIMO_MES + 0.5) ? 1 : 0}")

if [ "$AVISO_DIA" -eq 1 ] || [ "$AVISO_MES" -eq 1 ]; then
    COSTE_ESTIMADO=$(awk "BEGIN {printf \"%.2f\", $TX_MES_GB * $PRECIO_GB}")
    
    TITULO="⚠️ *ALERTA DE TRÁFICO VPS*"
    [ "$AVISO_MES" -eq 1 ] && TITULO="🚨 *ALERTA CRÍTICA: LÍMITE MENSUAL*"

    MENSAJE="$TITULO
-------------------------------
📅 *CONSUMO DE HOY:*
📥 Descarga: $RX_DIA_GB GB
📤 Subida: $TX_DIA_GB GB
📊 Total Día: *$TOTAL_DIA_GB GB* / $LIMITE_DIARIO GB

🗓️ *CONSUMO DEL MES ($(date +%B)):*
📥 Descarga: $RX_MES_GB GB
📤 Subida: $TX_MES_GB GB
✨ Total Mes: *$TOTAL_MES_GB GB* / $LIMITE_MENSUAL GB
💰 Coste Estimado (TX): *\$${COSTE_ESTIMADO}*
-------------------------------
🌐 Interfaz: $INTERFACE
🖥️ Hostname: $(hostname)"

    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$MENSAJE" \
        -d parse_mode="Markdown"

    echo "$TOTAL_DIA_GB" > "$TEMP_DIA"
    echo "$TOTAL_MES_GB" > "$TEMP_MES"
fi
