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

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- 1. CONFIGURACIÓN DE RUTAS ---
STAT="/usr/bin/stat"; CHMOD="/usr/bin/chmod"; VNSTAT="/usr/bin/vnstat"
AWK="/usr/bin/awk"; JQ="/usr/bin/jq"; DATE="/usr/bin/date"; CURL="/usr/bin/curl"
REPO_URL="https://github.com/LadyKernel/MyIronGuard"

# --- 2. CARGA DE CONFIGURACIÓN ---
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$DIR/.env"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
else
    echo "❌ Error: .env no encontrado." >&2; exit 1
fi

# Valores por defecto si no están en .env
INTERFACES=${INTERFACES:-"eth0"}
UMBRAL_ALERTA=${UMBRAL_ALERTA:-0.9}
LIMITE_DIARIO=${LIMITE_DIARIO:-0.1}
LIMITE_MENSUAL=${LIMITE_MENSUAL:-900}
PRECIO_GB=${PRECIO_GB:-0}
STEP_D=0.05; STEP_M=0.1

# --- 3. FUNCIONES AUXILIARES ---
calc_gb() { $AWK -v b="$1" 'BEGIN {printf "%.2f", b/1073741824}'; }
formato_dinamico() { $AWK -v n="$1" 'BEGIN { if (n < 1 && n > 0) printf "%.2f MB", n*1024; else printf "%.2f GB", n; }'; }

# --- 4. BUCLE DE PROCESAMIENTO ---
for IFACE in $INTERFACES; do
    # Limpieza de variables para evitar "unbound"
    IFACE_UPPER=$(echo "$IFACE" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    
    # Obtenemos límites dinámicos o usamos los globales
    VAR_DIA="LIMITE_DIARIO_${IFACE_UPPER}"
    VAR_MES="LIMITE_MENSUAL_${IFACE_UPPER}"
    LIM_DIA=${!VAR_DIA:-$LIMITE_DIARIO}
    LIM_MES=${!VAR_MES:-$LIMITE_MENSUAL}

    STATE_DIA="$DIR/.alert_state_dia_${IFACE}.txt"
    STATE_MES="$DIR/.alert_state_mes_${IFACE}.txt"
    CONTROL_MES="$DIR/.last_month_${IFACE}.txt"

    # Reset mensual (si los archivos no existen, se crean con 0)
    MES_ACTUAL=$($DATE +%m)
    [ -f "$CONTROL_MES" ] || echo "$MES_ACTUAL" > "$CONTROL_MES"
    [ -f "$STATE_DIA" ] || echo "0" > "$STATE_DIA"
    [ -f "$STATE_MES" ] || echo "0" > "$STATE_MES"

    if [ "$MES_ACTUAL" != "$(cat "$CONTROL_MES")" ]; then
        echo "0" > "$STATE_DIA"; echo "0" > "$STATE_MES"; echo "$MES_ACTUAL" > "$CONTROL_MES"
    fi

    # Captura
    $VNSTAT -u -i "$IFACE" > /dev/null 2>&1 || true
    JSON_DATA=$($VNSTAT -i "$IFACE" --json 2>/dev/null)
    [ -z "$JSON_DATA" ] || [ "$JSON_DATA" == "null" ] && continue

    RX_D=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.day // .interfaces[0].traffic.days) | last | .rx // 0')
    TX_D=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.day // .interfaces[0].traffic.days) | last | .tx // 0')
    RX_M=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months) | last | .rx // 0')
    TX_M=$(echo "$JSON_DATA" | $JQ -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months) | last | .tx // 0')

    TOTAL_DIA_GB=$($AWK -v r=$(calc_gb "$RX_D") -v t=$(calc_gb "$TX_D") 'BEGIN {printf "%.2f", r+t}')
    TOTAL_MES_GB=$($AWK -v r=$(calc_gb "$RX_M") -v t=$(calc_gb "$TX_M") 'BEGIN {printf "%.2f", r+t}')
    
    # Cálculo estado
    PORC_MES=$(awk -v t="$TOTAL_MES_GB" -v l="$LIM_MES" 'BEGIN {printf "%.1f", (t/l)*100}')
    if (( $(echo "$PORC_MES >= 90" | bc -l) )); then ESTADO="CRITICAL"; ICONO="🔴"; ES_CRITICO=1
    elif (( $(echo "$PORC_MES >= 70" | bc -l) )); then ESTADO="WARNING"; ICONO="🟡"; ES_CRITICO=0
    else ESTADO="NORMAL"; ICONO="🟢"; ES_CRITICO=0; fi

    ULTIMO_ALERTA_DIA=$(cat "$STATE_DIA")
    ULTIMO_ALERTA_MES=$(cat "$STATE_MES")
    
    AVISO_DIA=$($AWK -v t="$TOTAL_DIA_GB" -v l="$LIM_DIA" -v u="$UMBRAL_ALERTA" -v last="$ULTIMO_ALERTA_DIA" -v s="$STEP_D" 'BEGIN {print (t>=last+s || t>=l*u) ? 1 : 0}')
    AVISO_MES=$($AWK -v t="$TOTAL_MES_GB" -v l="$LIM_MES" -v u="$UMBRAL_ALERTA" -v last="$ULTIMO_ALERTA_MES" -v s="$STEP_M" 'BEGIN {print (t>=last+s || t>=l*u) ? 1 : 0}')

    # Consola
    if [ -t 1 ]; then
        echo "======================================"
        echo "📊 MONITOR DE RED (Interfaz: $IFACE)"
        echo "======================================"
        echo "📅 Tráfico HOY: $TOTAL_DIA_GB GB"
        echo "🗓️  Tráfico MES: $TOTAL_MES_GB GB / $LIM_MES GB ($PORC_MES%)"
        echo -e "🚦 Estado: $ICONO $ESTADO"
        [ "$ES_CRITICO" -eq 1 ] && echo -e "⚠️ ¡Alerta! Repo: $REPO_URL"
        echo "======================================"
        echo "🛡️   MyIronGuard v2.0 (PolyForm NC)"
        echo "🏢 Empresa: hola@lksys.es"
        echo "⭐ Si te gusta el script, apóyame con una estrella en:"
        echo -e "🔗 \e[1;34mRepo: $REPO_URL\e[0m"
        echo "======================================"
    fi

    # Telegram
    if [ "$AVISO_DIA" -eq 1 ] || [ "$AVISO_MES" -eq 1 ]; then
        TOKEN_VAR="TOKEN_${IFACE_UPPER}"
        CHAT_ID_VAR="CHAT_ID_${IFACE_UPPER}"
        T_VAL="${!TOKEN_VAR:-$TOKEN}"; C_VAL="${!CHAT_ID_VAR:-$CHAT_ID}"
        
        if [[ -n "$T_VAL" && -n "$C_VAL" ]]; then
            COSTE=$($AWK -v tx="$TOTAL_MES_GB" -v lim="$LIM_MES" -v p="$PRECIO_GB" 'BEGIN {printf "%.2f", (tx>lim) ? (tx-lim)*p : 0.00}')
            TITULO=$([ "$ES_CRITICO" -eq 1 ] && echo "⚠️ *ALERTA CRÍTICA*" || echo "ℹ️ *INFORME VPS*")
            FOOTER=$([ "$ES_CRITICO" -eq 1 ] && echo -e "\n⭐ *¡Apoya el proyecto!*\n$REPO_URL" || echo "")

            MENSAJE=$(printf "%s (%s)\n\n📆 *Hoy*\n┣ 📊 Total Día: *%s* / %s GB\n\n🗓️ *Consumo mes (%s):*\n┣ 📦 Total Mes: *%s* / %s GB (%s%%)\n┣ 💰 Coste Extra: *\$%s*\n┗ 🚦 Estado: %s *%s*%s" \
            "$TITULO" "$IFACE" "$(formato_dinamico "$TOTAL_DIA_GB")" "$LIM_DIA" "$($DATE +%B)" \
            "$(formato_dinamico "$TOTAL_MES_GB")" "$LIM_MES" "$PORC_MES" "$COSTE" "$ICONO" "$ESTADO" "$FOOTER")

            TELEGRAM_MESSAGE=$($JQ -n --arg cid "$C_VAL" --arg txt "$MENSAJE" '{chat_id: $cid, text: $txt, parse_mode: "Markdown"}')
            $CURL -s -X POST "https://api.telegram.org/bot$T_VAL/sendMessage" -H "Content-Type: application/json" -d "$TELEGRAM_MESSAGE" > /dev/null
            echo "$TOTAL_DIA_GB" > "$STATE_DIA"; echo "$TOTAL_MES_GB" > "$STATE_MES"
        fi
    fi
done
