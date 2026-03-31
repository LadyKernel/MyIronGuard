#!/bin/bash

# --- 1. CARGA DE CONFIGURACIÓN ---
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$DIR/.env" ]; then
    sed -i 's/\r//g' "$DIR/.env"
    source "$DIR/.env"
else
    echo "❌ Error: Archivo .env no encontrado en $DIR"
    exit 1
fi

# INTERFAZ FIJA PARA VPS ESTÁNDAR
INTERFACE="ens6"

LIMITE_DIARIO=${LIMITE_DIARIO:-30}
LIMITE_MENSUAL=${LIMITE_MENSUAL:-900}
PRECIO_GB=${PRECIO_GB:-0}

TEMP_DIA="/tmp/ultimo_trafico_dia_${INTERFACE}.txt"
TEMP_MES="/tmp/ultimo_trafico_mes_${INTERFACE}.txt"

if [ "$DEBUG" == "1" ]; then echo "--- [DEBUG VPS] --- Interface: $INTERFACE | Límite Día: $LIMITE_DIARIO GB | Límite Mes: $LIMITE_MENSUAL GB"; fi

# --- 2. CAPTURA DE DATOS ---
vnstat -u -i "$INTERFACE" > /dev/null 2>&1
JSON_DATA=$(vnstat -i "$INTERFACE" --json 2>/dev/null)

get_val() {
    local key_path="$1"
    local alt_path="$2"
    local val=$(echo "$JSON_DATA" | jq -r "$key_path" 2>/dev/null)
    if [[ "$val" == "null" || -z "$val" ]] && [ ! -z "$alt_path" ]; then
        val=$(echo "$JSON_DATA" | jq -r "$alt_path" 2>/dev/null)
    fi
    if [[ "$val" == "null" || -z "$val" ]]; then echo 0; else echo "$val"; fi
}

RX_DIA_BYTES=$(get_val '.interfaces[0].traffic.day[-1].rx' '.interfaces[0].traffic.days[-1].rx')
TX_DIA_BYTES=$(get_val '.interfaces[0].traffic.day[-1].tx' '.interfaces[0].traffic.days[-1].tx')
RX_MES_BYTES=$(get_val '.interfaces[0].traffic.month[-1].rx' '.interfaces[0].traffic.months[-1].rx')
TX_MES_BYTES=$(get_val '.interfaces[0].traffic.month[-1].tx' '.interfaces[0].traffic.months[-1].tx')

# --- 3. CONVERSIÓN A GB ---
DIVISOR=1073741824
TOTAL_DIA_GB=$(awk "BEGIN {printf \"%.2f\", ($RX_DIA_BYTES + $TX_DIA_BYTES) / $DIVISOR}")
TOTAL_MES_GB=$(awk "BEGIN {printf \"%.2f\", ($RX_MES_BYTES + $TX_MES_BYTES) / $DIVISOR}")
RX_DIA_GB=$(awk "BEGIN {printf \"%.2f\", $RX_DIA_BYTES / $DIVISOR}")
TX_DIA_GB=$(awk "BEGIN {printf \"%.2f\", $TX_DIA_BYTES / $DIVISOR}")
RX_MES_GB=$(awk "BEGIN {printf \"%.2f\", $RX_MES_BYTES / $DIVISOR}")
TX_MES_GB=$(awk "BEGIN {printf \"%.2f\", $TX_MES_BYTES / $DIVISOR}")

# --- 4. LÓGICA DE ALERTAS ---
[ -f "$TEMP_DIA" ] || echo "0" > "$TEMP_DIA"
[ -f "$TEMP_MES" ] || echo "0" > "$TEMP_MES"
ULTIMO_DIA=$(cat "$TEMP_DIA")
ULTIMO_MES=$(cat "$TEMP_MES")

AVISO_DIA=$(awk "BEGIN {print ($TOTAL_DIA_GB > $LIMITE_DIARIO && $TOTAL_DIA_GB >= $ULTIMO_DIA + 0.05) ? 1 : 0}")
AVISO_MES=$(awk "BEGIN {print ($TOTAL_MES_GB > $LIMITE_MENSUAL && $TOTAL_MES_GB >= $ULTIMO_MES + 0.1) ? 1 : 0}")

# --- 5. ENVÍO DE ALERTA ---
if [ "$AVISO_DIA" -eq 1 ] || [ "$AVISO_MES" -eq 1 ]; then
    COSTE_ESTIMADO=$(awk "BEGIN {printf \"%.2f\", $TX_MES_GB * $PRECIO_GB}")

    formato_dinamico() {
        local val_gb="$1"
        local es_menor=$(awk "BEGIN {print ($val_gb < 1.0) ? 1 : 0}")
        if [ "$es_menor" -eq 1 ]; then awk "BEGIN {printf \"%.2f MB\", $val_gb * 1024}"; else echo "$val_gb GB"; fi
    }

    TITULO="⚠️ *ALERTA DE TRÁFICO VPS*"
    [ "$AVISO_MES" -eq 1 ] && TITULO="🚨 *ALERTA CRÍTICA VPS: LÍMITE MENSUAL*"

    MENSAJE="$TITULO
-------------------------------
📅 *CONSUMO DE HOY:*
📥 Descarga: $(formato_dinamico "$RX_DIA_GB")
📤 Subida: $(formato_dinamico "$TX_DIA_GB")
📊 Total Día: *$(formato_dinamico "$TOTAL_DIA_GB")* / $LIMITE_DIARIO GB

🗓️ *CONSUMO DEL MES ($(date +%B)):*
📥 Descarga: $(formato_dinamico "$RX_MES_GB")
📤 Subida: $(formato_dinamico "$TX_MES_GB")
✨ Total Mes: *$(formato_dinamico "$TOTAL_MES_GB")* / $LIMITE_MENSUAL GB
💰 Coste Estimado (TX): *\$${COSTE_ESTIMADO}*
-------------------------------
🌐 Interfaz: $INTERFACE
🖥️ Hostname: $(hostname)"

    JSON_PAYLOAD=$(jq -n --arg cid "$CHAT_ID" --arg txt "$MENSAJE" '{chat_id: $cid, text: $txt, parse_mode: "Markdown"}')
    RESPUESTA=$(curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "$JSON_PAYLOAD")

    if echo "$RESPUESTA" | grep -q '"ok":true'; then
        echo "$TOTAL_DIA_GB" > "$TEMP_DIA"
        echo "$TOTAL_MES_GB" > "$TEMP_MES"
    fi
fi
