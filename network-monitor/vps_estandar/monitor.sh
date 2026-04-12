#!/bin/bash
# -------------------------------------------------------------------------
# Proyecto: VPS Network Monitor
# Author: LadyKerel
# Repository: https://github.com/LadyKernel/MyIronGuard/tree/main/network-monitor
# Licencia: MIT
# Versión:  1.1.0
# -------------------------------------------------------------------------

# Aseguramos el formato numérico internacional (puntos en vez de comas)
export LC_ALL=C

# --- 1. CARGA DE CONFIGURACIÓN ---
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$DIR/.env" ]; then
    # Limpiamos retornos de carro por si se editó en Windows
    sed -i 's/\r//g' "$DIR/.env"
    export $(grep -v '^#' "$DIR/.env" | xargs)
else
    echo "❌ Error: Archivo .env no encontrado en $DIR"
    exit 1
fi

# Puedes poner la interfaz en el .env, si no, usa ens6 por defecto
INTERFACE=${INTERFACE:-"ens6"}

LIMITE_DIARIO=${LIMITE_DIARIO:-0.1}
LIMITE_MENSUAL=${LIMITE_MENSUAL:-900}
PRECIO_GB=${PRECIO_GB:-0}

# Moviendo los archivos de estado a la carpeta del script (evita líos de permisos en /tmp)
STATE_DIA="$DIR/.alert_state_dia_${INTERFACE}.txt"
STATE_MES="$DIR/.alert_state_mes_${INTERFACE}.txt"

# --- 2. CAPTURA DE DATOS (NATIVA Y ROBUSTA) ---
# Actualizamos vnstat antes de leer
vnstat -u -i "$INTERFACE" > /dev/null 2>&1
JSON_DATA=$(vnstat -i "$INTERFACE" --json 2>/dev/null)

if [ -z "$JSON_DATA" ]; then
    echo "❌ Error: No se pudo obtener datos JSON de vnstat para la interfaz $INTERFACE."
    exit 1
fi

# Extracción a prueba de balas (busca 'day/month' o 'days/months' y coge el último valor)
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
[ -f "$STATE_DIA" ] || echo "0" > "$STATE_DIA"
[ -f "$STATE_MES" ] || echo "0" > "$STATE_MES"
ULTIMO_ALERTA_DIA=$(cat "$STATE_DIA")
ULTIMO_ALERTA_MES=$(cat "$STATE_MES")

# Comprueba si superamos el límite Y si ha subido al menos 0.05GB desde el último aviso
AVISO_DIA=$(awk -v t_dia="$TOTAL_DIA_GB" -v l_dia="$LIMITE_DIARIO" -v u_dia="$ULTIMO_ALERTA_DIA" 'BEGIN {print (t_dia > l_dia && t_dia >= u_dia + 0.05) ? 1 : 0}')
AVISO_MES=$(awk -v t_mes="$TOTAL_MES_GB" -v l_mes="$LIMITE_MENSUAL" -v u_mes="$ULTIMO_ALERTA_MES" 'BEGIN {print (t_mes > l_mes && t_mes >= u_mes + 0.1) ? 1 : 0}')

# --- SALIDA POR PANTALLA (SI SE EJECUTA A MANO) ---
if [ -t 1 ]; then
    echo "======================================"
    echo "📊 MONITOR DE RED (Interfaz: $INTERFACE)"
    echo "======================================"
    echo "📅 Tráfico HOY: $TOTAL_DIA_GB GB (Límite: $LIMITE_DIARIO GB)"
    echo "🗓️ Tráfico MES: $TOTAL_MES_GB GB (Límite: $LIMITE_MENSUAL GB)"
    echo "--------------------------------------"
    echo "🔔 Último aviso Telegram (Hoy): ${ULTIMO_ALERTA_DIA} GB"
    echo "🔔 Último aviso Telegram (Mes): ${ULTIMO_ALERTA_MES} GB"

    if [ "$AVISO_DIA" -eq 1 ] || [ "$AVISO_MES" -eq 1 ]; then
        echo "⚠️ LÍMITE SUPERADO - Enviando alerta a Telegram..."
    else
        echo "✅ Todo en orden. No se enviarán alertas."
    fi
    echo "======================================"
fi

# --- 5. ENVÍO DE ALERTA A TELEGRAM ---
if [ "$AVISO_DIA" -eq 1 ] || [ "$AVISO_MES" -eq 1 ]; then

#    COSTE_ESTIMADO=$(awk -v tx="$TX_MES_GB" -v precio="$PRECIO_GB" 'BEGIN {printf "%.2f", tx * precio}')

    # Cálculo seguro del coste

    COSTE_ESTIMADO=$(LC_NUMERIC=C awk -v tx="$TX_MES_GB" -v precio="$PRECIO_GB" 'BEGIN {printf "%.2f", tx * precio}')

    formato_dinamico() {

        local val_gb="$1"

        local es_menor=$(awk "BEGIN {print ($val_gb < 1.0) ? 1 : 0}")

        if [ "$es_menor" -eq 1 ]; then awk "BEGIN {printf \"%.2f MB\", $val_gb * 1024}"; else echo "$val_gb GB"; fi

    }
    # Función para mostrar MB si es menor a 1 GB
    formato_dinamico() {
        local val_gb="$1"
        local es_menor=$(awk "BEGIN {print ($val_gb < 1.0) ? 1 : 0}")
        if [ "$es_menor" -eq 1 ]; then
            awk "BEGIN {printf \"%.2f MB\", $val_gb * 1024}"
        else
            echo "$val_gb GB"
        fi
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

    # Asegúrate de que el TOKEN y CHAT_ID existen
    if [ ! -z "$TOKEN" ] && [ ! -z "$CHAT_ID" ]; then
        TELEGRAM_MESSAGE_DATA=$(jq -n --arg cid "$CHAT_ID" --arg txt "$MENSAJE" '{chat_id: $cid, text: $txt, parse_mode: "Markdown"}')
        RESPUESTA=$(curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "$TELEGRAM_MESSAGE_DATA")

        # Solo guardamos el estado SI el mensaje de Telegram se envió correctamente
        if echo "$RESPUESTA" | grep -q '"ok":true'; then
            echo "$TOTAL_DIA_GB" > "$STATE_DIA"
            echo "$TOTAL_MES_GB" > "$STATE_MES"
        fi
    fi
fi
