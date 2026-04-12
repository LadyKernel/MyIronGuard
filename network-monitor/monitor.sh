#!/bin/bash
# -------------------------------------------------------------------------
# Proyecto: GCloud Network Monitor
# Author: LadyKernel
# Repository: https://github.com/LadyKernel/MyIronGuard/tree/main/network-monitor
# Licencia:    Creative Commons BY-NC 4.0 (Uso No Comercial)
# Copyright:   (c) 2026 LadyKernel
# Este programa es software libre: puedes redistribuirlo y/o modificarlo 
# bajo los términos de la Licencia Pública General GNU.
# USO COMERCIAL: Si eres una empresa y quieres usar este software 
# con fines lucrativos, contacta conmigo en hola@lksys.es.
# -------------------------------------------------------------------------

# --- 1. CARGA DE CONFIGURACIÓN ---
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$DIR/.env" ]; then
    source "$DIR/.env"
    echo "✅ Archivo .env cargado."
else
    echo "❌ Error: Archivo .env no encontrado en $DIR"
    exit 1
fi

# Valores por defecto para evitar errores de AWK
LIMITE_DIARIO=${LIMITE_DIARIO:-0}
LIMITE_MENSUAL=${LIMITE_MENSUAL:-0}
PRECIO_GB=${PRECIO_GB:-0}
INTERFACE=${INTERFACE:-"eth0"}

TEMP_DIA="/tmp/ultimo_trafico_dia_$INTERFACE.txt"
TEMP_MES="/tmp/ultimo_trafico_mes_$INTERFACE.txt"

# --- 2. CAPTURA DE DATOS (JSON) ---
# Forzamos la actualización de base de datos de vnstat
vnstat -u -i "$INTERFACE" > /dev/null 2>&1

JSON_DATA=$(vnstat -i "$INTERFACE" --json)

# Extraer datos con validación para versiones antiguas y nuevas de vnstat
DIA_RAW=$(echo "$JSON_DATA" | jq -r '.interfaces[0].traffic.day[0] // empty')
MES_RAW=$(echo "$JSON_DATA" | jq -r '.interfaces[0].traffic.month[0] // empty')

# Si están vacíos, ponemos 0 para que awk no rompa
RX_DIA_KIB=$(echo "$DIA_RAW" | jq -r '.rx // 0')
TX_DIA_KIB=$(echo "$DIA_RAW" | jq -r '.tx // 0')
RX_MES_KIB=$(echo "$MES_RAW" | jq -r '.rx // 0')
TX_MES_KIB=$(echo "$MES_RAW" | jq -r '.tx // 0')

# --- 3. CONVERSIÓN A GB ---
TOTAL_DIA_GB=$(awk "BEGIN {printf \"%.2f\", ($RX_DIA_KIB + $TX_DIA_KIB) / 1048576}")
TOTAL_MES_GB=$(awk "BEGIN {printf \"%.2f\", ($RX_MES_KIB + $TX_MES_KIB) / 1048576}")
TX_MES_GB=$(awk "BEGIN {printf \"%.2f\", $TX_MES_KIB / 1048576}")
RX_DIA_GB=$(awk "BEGIN {printf \"%.2f\", $RX_DIA_KIB / 1048576}")
TX_DIA_GB=$(awk "BEGIN {printf \"%.2f\", $TX_DIA_KIB / 1048576}")
RX_MES_GB=$(awk "BEGIN {printf \"%.2f\", $RX_MES_KIB / 1048576}")
TX_MES_GB=$(awk "BEGIN {printf \"%.2f\", $TX_MES_KIB / 1048576}")

# --- 5. LÓGICA DE ALERTAS ---
[ -f "$TEMP_DIA" ] || echo "0" > "$TEMP_DIA"
[ -f "$TEMP_MES" ] || echo "0" > "$TEMP_MES"

ULTIMO_DIA=$(cat "$TEMP_DIA")
ULTIMO_MES=$(cat "$TEMP_MES")

# IMPORTANTE: Comparamos como números flotantes con awk
AVISO_DIA=$(awk "BEGIN {print ($TOTAL_DIA_GB > $LIMITE_DIARIO && $TOTAL_DIA_GB >= $ULTIMO_DIA + 0.1) ? 1 : 0}")
AVISO_MES=$(awk "BEGIN {print ($TOTAL_MES_GB > $LIMITE_MENSUAL && $TOTAL_MES_GB >= $ULTIMO_MES + 0.5) ? 1 : 0}")

if [ "$AVISO_DIA" -eq 1 ] || [ "$AVISO_MES" -eq 1 ]; then
    echo "🚀 Enviando alerta a Telegram..."
    
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
else
    echo "ℹ️ No se cumplen las condiciones para enviar alerta (límites no superados o ya notificado)."
fi
