#!/bin/bash
# -------------------------------------------------------------------------
# Proyecto: GCloud Network Monitor
# Author: LadyKernel
# Repository: https://github.com/LadyKernel/MyIronGuard/tree/main/network-monitor
# Licencia:    Creative Commons BY-NC 4.0 (Uso No Comercial)
# Copyright:   (c) 2026 LadyKernel
# Copyright:   (c) 2026 LadyKernel
# -------------------------------------------------------------------------
# Este programa es gratuito para uso personal y educativo. 
# QUEDA PROHIBIDO EL USO COMERCIAL O LUCRATIVO SIN PERMISO.
# Si eres una empresa y quieres usar este software, contacta en: hola@lksys.es
# -------------------------------------------------------------------------


# --- 1. CARGA DE CONFIGURACIÓN ---
# Aseguramos formato numérico internacional (para evitar errores con comas/puntos)
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$DIR/.env" ]; then
    sed -i 's/\r//g' "$DIR/.env"
    source "$DIR/.env"
else
    echo "❌ Error: Archivo .env no encontrado en $DIR"
    exit 1
fi

# INTERFAZ PARA GOOGLE CLOUD
INTERFACE="ens4"

LIMITE_DIARIO=${LIMITE_DIARIO:-6}
LIMITE_MENSUAL=${LIMITE_MENSUAL:-180}
PRECIO_GB=${PRECIO_GB:-0}

# Usamos archivos ocultos en el mismo directorio para persistencia
TEMP_DIA="$DIR/.ultimo_trafico_dia_${INTERFACE}.txt"
TEMP_MES="$DIR/.ultimo_trafico_mes_${INTERFACE}.txt"

if [ "$DEBUG" == "1" ]; then echo "--- [DEBUG GCP] --- Interface: $INTERFACE | Límite Día: $LIMITE_DIARIO GB | Límite Mes: $LIMITE_MENSUAL GB"; fi

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

# FIX: Selector universal para day/days y month/months usando '| last'
RX_DIA_BYTES=$(echo "$JSON_DATA" | jq -r '(.interfaces[0].traffic.day // .interfaces[0].traffic.days) | last | .rx // 0')
TX_DIA_BYTES=$(echo "$JSON_DATA" | jq -r '(.interfaces[0].traffic.day // .interfaces[0].traffic.days) | last | .tx // 0')
RX_MES_BYTES=$(echo "$JSON_DATA" | jq -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months) | last | .rx // 0')
TX_MES_BYTES=$(echo "$JSON_DATA" | jq -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months) | last | .tx // 0')

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

AVISO_DIA=$(awk -v t="$TOTAL_DIA_GB" -v l="$LIMITE_DIARIO" -v u="$ULTIMO_DIA" 'BEGIN {print (t > l && t >= u + 0.05) ? 1 : 0}')
AVISO_MES=$(awk -v t="$TOTAL_MES_GB" -v l="$LIMITE_MENSUAL" -v u="$ULTIMO_MES" 'BEGIN {print (t > l && t >= u + 0.1) ? 1 : 0}')

# --- SALIDA POR PANTALLA (Solo si se ejecuta a mano) ---
if [ -t 1 ]; then
    echo "======================================"
    echo "📊 MONITOR DE RED GCP (Interfaz: $INTERFACE)"
    echo "======================================"
    echo "📅 Tráfico HOY: $TOTAL_DIA_GB GB (Límite: $LIMITE_DIARIO GB)"
    echo "🗓️ Tráfico MES: $TOTAL_MES_GB GB (Límite: $LIMITE_MENSUAL GB)"
    echo "--------------------------------------"
    echo "🔔 Último aviso Telegram (Hoy): $ULTIMO_DIA GB"
    echo "🔔 Último aviso Telegram (Mes): $ULTIMO_MES GB"

    if [ "$AVISO_DIA" -eq 1 ] || [ "$AVISO_MES" -eq 1 ]; then
        echo "⚠️ LÍMITE SUPERADO - Procesando alerta..."
    else
        echo "✅ Todo en orden. No se enviarán alertas."
    fi
    echo "======================================"
fi

# --- 5. ENVÍO DE ALERTA ---
if [ "$AVISO_DIA" -eq 1 ] || [ "$AVISO_MES" -eq 1 ]; then
    COSTE_ESTIMADO=$(awk -v tx="$TX_MES_GB" -v p="$PRECIO_GB" 'BEGIN {printf "%.2f", tx * p}')

    formato_dinamico() {
        local val_gb="$1"
        local es_menor=$(awk "BEGIN {print ($val_gb < 1.0) ? 1 : 0}")
        if [ "$es_menor" -eq 1 ]; then awk "BEGIN {printf \"%.2f MB\", $val_gb * 1024}"; else echo "$val_gb GB"; fi
    }

    TITULO="⚠️ *ALERTA DE TRÁFICO GCLOUD*"
    [ "$AVISO_MES" -eq 1 ] && TITULO="🚨 *ALERTA CRÍTICA GCLOUD: LÍMITE MENSUAL*"

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

    TELEGRAM_MESSAGE_DATA=$(jq -n --arg cid "$CHAT_ID" --arg txt "$MENSAJE" '{chat_id: $cid, text: $txt, parse_mode: "Markdown"}')
    RESPUESTA=$(curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "$TELEGRAM_MESSAGE_DATA")

    if echo "$RESPUESTA" | grep -q '"ok":true'; then
        echo "$TOTAL_DIA_GB" > "$TEMP_DIA"
        echo "$TOTAL_MES_GB" > "$TEMP_MES"
    fi
fi
