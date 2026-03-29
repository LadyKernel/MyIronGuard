#!/bin/bash

# --- 1. CARGA DE CONFIGURACIÓN ---
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$DIR/.env" ]; then
    source "$DIR/.env"
else
    echo "❌ Error: Archivo .env no encontrado en $DIR"
    exit 1
fi

LIMITE_DIARIO=${LIMITE_DIARIO:-0}
LIMITE_MENSUAL=${LIMITE_MENSUAL:-0}
PRECIO_GB=${PRECIO_GB:-0}
INTERFACE=${INTERFACE:-"ens4"}

TEMP_DIA="/tmp/ultimo_trafico_dia_$INTERFACE.txt"
TEMP_MES="/tmp/ultimo_trafico_mes_$INTERFACE.txt"

# --- 2. CAPTURA DE DATOS (TEXTO GCP) ---
vnstat -u -i "$INTERFACE" > /dev/null 2>&1
DATOS_TEXTO=$(vnstat -i "$INTERFACE" --short 2>/dev/null)

# Función para convertir MiB, KiB o GiB a GB puro
convertir_a_gb() {
    local valor=$(echo "$1" | tr ',' '.')
    local unidad="$2"
    
    if [[ -z "$valor" || "$valor" == "." ]]; then
        echo "0.00"
    elif [[ "$unidad" == *"MiB"* || "$unidad" == *"MB"* ]]; then
        awk "BEGIN {printf \"%.2f\", $valor / 1024}"
    elif [[ "$unidad" == *"KiB"* || "$unidad" == *"KB"* ]]; then
        awk "BEGIN {printf \"%.2f\", $valor / 1048576}"
    elif [[ "$unidad" == *"GiB"* || "$unidad" == *"GB"* ]]; then
        printf "%.2f" "$valor"
    else
        echo "0.00"
    fi
}

# --- EXTRAER DÍA ---
LINEA_DIA=$(echo "$DATOS_TEXTO" | grep "today")
if [ -n "$LINEA_DIA" ]; then
    RX_D_VAL=$(echo "$LINEA_DIA" | cut -d'/' -f1 | awk '{print $(NF-1)}')
    RX_D_UNI=$(echo "$LINEA_DIA" | cut -d'/' -f1 | awk '{print $NF}')
    TX_D_VAL=$(echo "$LINEA_DIA" | cut -d'/' -f2 | awk '{print $1}')
    TX_D_UNI=$(echo "$LINEA_DIA" | cut -d'/' -f2 | awk '{print $2}')
    TOT_D_VAL=$(echo "$LINEA_DIA" | cut -d'/' -f3 | awk '{print $1}')
    TOT_D_UNI=$(echo "$LINEA_DIA" | cut -d'/' -f3 | awk '{print $2}')
fi

RX_DIA_GB=$(convertir_a_gb "$RX_D_VAL" "$RX_D_UNI")
TX_DIA_GB=$(convertir_a_gb "$TX_D_VAL" "$TX_D_UNI")
TOTAL_DIA_GB=$(convertir_a_gb "$TOT_D_VAL" "$TOT_D_UNI")

# --- EXTRAER MES ---
MES_ACTUAL=$(date +%Y-%m)
LINEA_MES=$(echo "$DATOS_TEXTO" | grep "$MES_ACTUAL" | head -n 1)
if [ -n "$LINEA_MES" ]; then
    RX_M_VAL=$(echo "$LINEA_MES" | cut -d'/' -f1 | awk '{print $(NF-1)}')
    RX_M_UNI=$(echo "$LINEA_MES" | cut -d'/' -f1 | awk '{print $NF}')
    TX_M_VAL=$(echo "$LINEA_MES" | cut -d'/' -f2 | awk '{print $1}')
    TX_M_UNI=$(echo "$LINEA_MES" | cut -d'/' -f2 | awk '{print $2}')
    TOT_M_VAL=$(echo "$LINEA_MES" | cut -d'/' -f3 | awk '{print $1}')
    TOT_M_UNI=$(echo "$LINEA_MES" | cut -d'/' -f3 | awk '{print $2}')
fi

RX_MES_GB=$(convertir_a_gb "$RX_M_VAL" "$RX_M_UNI")
TX_MES_GB=$(convertir_a_gb "$TX_M_VAL" "$TX_M_UNI")
TOTAL_MES_GB=$(convertir_a_gb "$TOT_M_VAL" "$TOT_M_UNI")

# --- 3. LÓGICA DE ALERTAS ---
[ -f "$TEMP_DIA" ] || echo "0" > "$TEMP_DIA"
[ -f "$TEMP_MES" ] || echo "0" > "$TEMP_MES"

ULTIMO_DIA=$(cat "$TEMP_DIA")
ULTIMO_MES=$(cat "$TEMP_MES")

# REBAJAMOS EL MARGEN DE AVISO (0.001) PARA QUE LAS PRUEBAS FUNCIONEN SIEMPRE
AVISO_DIA=$(awk "BEGIN {print ($TOTAL_DIA_GB > $LIMITE_DIARIO && $TOTAL_DIA_GB >= $ULTIMO_DIA + 0.001) ? 1 : 0}")
AVISO_MES=$(awk "BEGIN {print ($TOTAL_MES_GB > $LIMITE_MENSUAL && $TOTAL_MES_GB >= $ULTIMO_MES + 0.01) ? 1 : 0}")

if [ "$AVISO_DIA" -eq 1 ] || [ "$AVISO_MES" -eq 1 ]; then
    echo "🚀 Límites superados. Preparando envío a Telegram..."
    
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

    # MÉTODO INFALIBLE: Empaquetar el texto en JSON puro para evitar que cURL lo rompa
    JSON_PAYLOAD=$(jq -n \
        --arg cid "$CHAT_ID" \
        --arg txt "$MENSAJE" \
        '{chat_id: $cid, text: $txt, parse_mode: "Markdown"}')

    RESPUESTA=$(curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD")

    # Verificamos si Telegram dio el OK
    if echo "$RESPUESTA" | grep -q '"ok":true'; then
        echo "$TOTAL_DIA_GB" > "$TEMP_DIA"
        echo "$TOTAL_MES_GB" > "$TEMP_MES"
        echo "✅ Alerta enviada con éxito a Telegram."
    else
        echo "❌ Fallo al enviar a Telegram. Respuesta de la API:"
        echo "$RESPUESTA" | jq '.'
    fi
else
    echo "ℹ️ No se cumplen las condiciones para enviar alerta (límites no superados o ya notificado)."
    echo "   - Consumo hoy: $TOTAL_DIA_GB GB (Límite: $LIMITE_DIARIO GB)"
    echo "   - Consumo mes: $TOTAL_MES_GB GB (Límite: $LIMITE_MENSUAL GB)"
fi
