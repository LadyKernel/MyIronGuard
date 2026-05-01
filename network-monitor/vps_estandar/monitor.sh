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


# --- 1. CONFIGURACIÓN DE RUTAS ---
STAT="/usr/bin/stat"
CHMOD="/usr/bin/chmod"
VNSTAT="/usr/bin/vnstat"
AWK="/usr/bin/awk"
JQ="/usr/bin/jq"
DATE="/usr/bin/date"
CURL="/usr/bin/curl"
REPO_URL="https://github.com/LadyKernel/MyIronGuard"

# --- 2. CARGA DE CONFIGURACIÓN ---
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$DIR/.env"

if [ -f "$ENV_FILE" ]; then
    PERMS=$($STAT -c "%a" "$ENV_FILE" 2>/dev/null)
    [ "$PERMS" != "600" ] && $CHMOD 600 "$ENV_FILE" 2>/dev/null
    sed -i 's/\r//g' "$ENV_FILE"
    set -a; . "$ENV_FILE"; set +a
else
    echo "❌ Error: Archivo .env no encontrado."
    exit 1
fi

# Parámetros por defecto
UMBRAL_ALERTA=${UMBRAL_ALERTA:-0.9}
LIMITE_DIARIO=${LIMITE_DIARIO:-0.1}
LIMITE_MENSUAL=${LIMITE_MENSUAL:-900}
PRECIO_GB=${PRECIO_GB:-0}
STEP_D=0.05
STEP_M=0.1

# --- 3. FUNCIONES AUXILIARES ---
calc_gb() { $AWK -v b="$1" 'BEGIN {printf "%.2f", b/1073741824}'; }
formato_dinamico() {
    $AWK -v n="$1" 'BEGIN { if (n < 1 && n > 0) printf "%.2f MB", n*1024; else printf "%.2f GB", n; }'
}

# --- 4. BUCLE DE PROCESAMIENTO ---
for IFACE in $INTERFACES; do
    IFACE_UPPER=$(echo "$IFACE" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    VAR_DIA="LIMITE_DIARIO_${IFACE_UPPER}"
    VAR_MES="LIMITE_MENSUAL_${IFACE_UPPER}"

    LIM_DIA=${!VAR_DIA:-$LIMITE_DIARIO}
    LIM_MES=${!VAR_MES:-$LIMITE_MENSUAL}

    STATE_DIA="$DIR/.alert_state_dia_${IFACE}.txt"
    STATE_MES="$DIR/.alert_state_mes_${IFACE}.txt"
    CONTROL_MES="$DIR/.last_month_${IFACE}.txt"

    # --- LÓGICA DE RESET MENSUAL ---
    MES_ACTUAL=$($DATE +%m)
    [ -f "$CONTROL_MES" ] || echo "$MES_ACTUAL" > "$CONTROL_MES"
    [ -f "$STATE_DIA" ] || echo "0" > "$STATE_DIA"
    [ -f "$STATE_MES" ] || echo "0" > "$STATE_MES"

    if [ "$MES_ACTUAL" != "$(cat "$CONTROL_MES")" ]; then
        echo "0" > "$STATE_DIA"
        echo "0" > "$STATE_MES"
        echo "$MES_ACTUAL" > "$CONTROL_MES"
        [ -t 1 ] && echo "♻️ Cambio de mes detectado en $IFACE. Reiniciando contadores."
    fi

    # Captura de datos
    $VNSTAT -u -i "$IFACE" > /dev/null 2>&1
    JSON_DATA=$($VNSTAT -i "$IFACE" --json 2>/dev/null)
    [ -z "$JSON_DATA" ] || [ "$JSON_DATA" == "null" ] && continue

    RX_D=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.day // .interfaces[0].traffic.days) | last | .rx // 0')
    TX_D=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.day // .interfaces[0].traffic.days) | last | .tx // 0')
    RX_M=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months) | last | .rx // 0')
    TX_M=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months) | last | .tx // 0')

    TOTAL_DIA_GB=$($AWK -v r=$(calc_gb "$RX_D") -v t=$(calc_gb "$TX_D") 'BEGIN {printf "%.2f", r+t}')
    TOTAL_MES_GB=$($AWK -v r=$(calc_gb "$RX_M") -v t=$(calc_gb "$TX_M") 'BEGIN {printf "%.2f", r+t}')

    ULTIMO_ALERTA_DIA=$(cat "$STATE_DIA")
    ULTIMO_ALERTA_MES=$(cat "$STATE_MES")

    # Comprobaciones
    ES_CRITICO=$($AWK -v td="$TOTAL_DIA_GB" -v ld="$LIM_DIA" -v tm="$TOTAL_MES_GB" -v lm="$LIM_MES" -v u="$UMBRAL_ALERTA" \
    'BEGIN {print (td >= (ld*u) || tm >= (lm*u)) ? 1 : 0}')

    AVISO_DIA=$($AWK -v t="$TOTAL_DIA_GB" -v l="$LIM_DIA" -v u="$UMBRAL_ALERTA" -v last="$ULTIMO_ALERTA_DIA" -v s="$STEP_D" \
    'BEGIN { inc=(t>=last+s); cross_u=(t>=l*u && last<l*u); print (inc || cross_u) ? 1 : 0 }')
    
    AVISO_MES=$($AWK -v t="$TOTAL_MES_GB" -v l="$LIM_MES" -v u="$UMBRAL_ALERTA" -v last="$ULTIMO_ALERTA_MES" -v s="$STEP_M" \
    'BEGIN { inc=(t>=last+s); cross_u=(t>=l*u && last<l*u); print (inc || cross_u) ? 1 : 0 }')

    # --- SALIDA CONSOLA ---
    if [ -t 1 ]; then
    echo "======================================"
    echo "📊 MONITOR DE RED (Interfaz: $IFACE)"
    echo "======================================"
    echo "📅 Tráfico HOY: $TOTAL_DIA_GB GB (Límite: $LIM_DIA GB)"
    echo "🗓️  Tráfico MES: $TOTAL_MES_GB GB (Límite: $LIM_MES GB)"
    echo "--------------------------------------"
    echo "🛡️  MyIronGuard v2.0 (PolyForm NC)"
    echo "🏢 Empresa: hola@lksys.es"
    echo "⭐ Si te gusta el script, apóyame con una estrella en:"
    echo -e "🔗 \e[1;34mRepo: $REPO_URL\e[0m"
    echo "======================================"
    fi
   
   # --- TELEGRAM ---
    if [ "$AVISO_DIA" -eq 1 ] || [ "$AVISO_MES" -eq 1 ]; then
        COSTE=$($AWK -v tx="$TOTAL_MES_GB" -v lim="$LIM_MES" -v p="$PRECIO_GB" 'BEGIN {if(tx>lim) printf "%.2f", (tx-lim)*p; else printf "0.00"}')
        [ "$ES_CRITICO" -eq 1 ] && TITULO="⚠️ *ALERTA VPS CRÍTICA*" || TITULO="⚠️ *ALERTA VPS*"
        
        MENSAJE="$TITULO ($IFACE)%0A"
        MENSAJE+="📅 Hoy: *$(formato_dinamico "$TOTAL_DIA_GB")* / $LIM_DIA GB%0A"
        MENSAJE+="🗓️ Mes: *$(formato_dinamico "$TOTAL_MES_GB")* / $LIM_MES GB%0A"
        MENSAJE+="💰 Extra: *\$${COSTE}*"
        [ "$ES_CRITICO" -eq 1 ] && MENSAJE+="%0A%0A⭐ *¡Apoya el proyecto con una estrella!*%0A$REPO_URL"

        if [[ -n "${TOKEN}" && -n "${CHAT_ID}" ]]; then
            $CURL -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID&text=$MENSAJE&parse_mode=Markdown" > /dev/null
            echo "$TOTAL_DIA_GB" > "$STATE_DIA"
            echo "$TOTAL_MES_GB" > "$STATE_MES"
        fi
    fi
done
