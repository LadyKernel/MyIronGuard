#!/usr/bin/env bash
# -------------------------------------------------------------------------
# Proyecto: Dskwap Guardian CLI - Storage & SWAP Resilience
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

# --- CARGAR VARIABLES DE ENTORNO ---
ENV_FILE="/etc/telegram_alerta.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "Error: No se encontró el archivo $ENV_FILE" >&2
    exit 1
fi

if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "Error: TELEGRAM_TOKEN o CHAT_ID no están definidos en $ENV_FILE" >&2
    exit 1
fi

# --- CONFIGURACIÓN ---
UMBRAL_DISCO=80
UMBRAL_SWAP=80
DIAS_LOGS=3
LOG_LOCAL="/var/log/limpieza_disco.log"
HOSTNAME=$(hostname)
FECHA=$(date "+%Y-%m-%d %H:%M:%S")
MODO="${1:-alerta}"

enviar_telegram() {
    local texto="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=$(printf '%b' "$texto")" \
        --data-urlencode "parse_mode=Markdown" > /dev/null
}

# ==========================================================
# MODO 1: EJECUCIÓN MANUAL DE LIMPIEZA (--limpiar)
# ==========================================================
if [ "$MODO" = "--limpiar" ]; then
    LIBRE_ANTES=$(df -m / | awk 'NR==2 {print $4}')
    DETALLES_LOCAL=""
    DETALLES_TG=""

    # A. Journald
    J_TIME=$(journalctl --vacuum-time=${DIAS_LOGS}d 2>&1 | grep "freed")
    J_SIZE=$(journalctl --vacuum-size=100M 2>&1 | grep "freed")
    if [ -n "$J_TIME" ] || [ -n "$J_SIZE" ]; then
        DETALLES_LOCAL+="  - Journald: ${J_TIME} ${J_SIZE}\n"
        DETALLES_TG+="• *Journald:* ${J_TIME} ${J_SIZE}\n"
    fi

    # B. Logs rotados
    BORRADOS=$(find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.old" \) -mtime +${DIAS_LOGS} -print -delete)
    if [ -n "$BORRADOS" ]; then
        CANT_B=$(echo "$BORRADOS" | wc -l)
        LISTA_COMPLETA=$(echo "$BORRADOS" | sed 's/^/    * /')
        DETALLES_LOCAL+="  - Logs rotados borrados (${CANT_B}):\n${LISTA_COMPLETA}\n"
        DETALLES_TG+="• *Logs rotados borrados:* ${CANT_B} archivos\n"
    fi

    # C. Logs >50MB truncados
    TRUNCADOS=$(find /var/log -type f -name "*.log" ! -path "$LOG_LOCAL" -size +50M -print -exec truncate -s 0 {} \;)
    if [ -n "$TRUNCADOS" ]; then
        LISTA_T=$(echo "$TRUNCADOS" | sed 's/^/    * /')
        DETALLES_LOCAL+="  - Logs >50MB vaciados:\n${LISTA_T}\n"
        DETALLES_TG+="• *Logs >50MB vaciados:* $(echo "$TRUNCADOS" | wc -l) archivos\n"
    fi

    # D. Caché APT
    APT_ANTES=$(du -sm /var/cache/apt/archives 2>/dev/null | awk '{print $1}')
    apt-get clean > /dev/null 2>&1
    APT_DESPUES=$(du -sm /var/cache/apt/archives 2>/dev/null | awk '{print $1}')
    APT_LIB=$(( ${APT_ANTES:-0} - ${APT_DESPUES:-0} ))
    if [ "$APT_LIB" -gt 0 ]; then
        DETALLES_LOCAL+="  - Caché APT: ${APT_LIB} MB liberados\n"
        DETALLES_TG+="• *Caché APT:* ${APT_LIB} MB liberados\n"
    fi

    LIBRE_DESPUES=$(df -m / | awk 'NR==2 {print $4}')
    RECUPERADO=$(( LIBRE_DESPUES - LIBRE_ANTES ))
    USO_DISCO=$(df -h / | awk 'NR==2 {print $5}')
    LIBRE_DISCO=$(df -h / | awk 'NR==2 {print $4}')

    # Guardar log local
    {
        echo "=========================================================="
        echo "[$FECHA] Limpieza MANUAL ejecutada en $HOSTNAME"
        echo "Estado posterior: Disco ${USO_DISCO} (${LIBRE_DISCO} libres) | Recuperado: ${RECUPERADO} MB"
        if [ -n "$DETALLES_LOCAL" ]; then
            echo -e "Acciones:\n${DETALLES_LOCAL}"
        else
            echo "Acciones: Ninguna (no había archivos candidatos)."
        fi
    } >> "$LOG_LOCAL"

    if [ -f "$LOG_LOCAL" ] && [ "$(wc -l < "$LOG_LOCAL")" -gt 500 ]; then
        tail -n 500 "$LOG_LOCAL" > "${LOG_LOCAL}.tmp" && mv "${LOG_LOCAL}.tmp" "$LOG_LOCAL"
    fi

    MSG_FIN="✅ *LIMPIEZA COMPLETADA EN ${HOSTNAME}*\n\n"
    MSG_FIN+="🧹 *Espacio recuperado:* ${RECUPERADO} MB\n"
    MSG_FIN+="💾 *Disco actual:* ${USO_DISCO} ocupado (${LIBRE_DISCO} libres)\n"
    [ -n "$DETALLES_TG" ] && MSG_FIN+="\n📋 *Resumen:*\n${DETALLES_TG}"
    MSG_FIN+="\n📝 _Detalle guardado en ${LOG_LOCAL}_"

    enviar_telegram "$MSG_FIN"
    echo "Limpieza completada. Espacio recuperado: ${RECUPERADO} MB. Disco actual: ${USO_DISCO} (${LIBRE_DISCO} libres)."
    exit 0
fi

# ==========================================================
# MODO 2: SIMULACIÓN Y ALERTA PREVENTIVA (CRON / --preview)
# ==========================================================
USO_DISCO=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
LIBRE_DISCO=$(df -h / | awk 'NR==2 {print $4}')
TOTAL_DISCO=$(df -h / | awk 'NR==2 {print $2}')

SWAP_TOTAL=$(LC_ALL=C free -m | awk '/^Swap:/ {print $2}')
SWAP_USADO=$(LC_ALL=C free -m | awk '/^Swap:/ {print $3}')
USO_SWAP=0
[ "$SWAP_TOTAL" -gt 0 ] && USO_SWAP=$(( SWAP_USADO * 100 / SWAP_TOTAL ))

# En cron solo alerta si supera umbral; con --preview fuerza la simulación
if [ "$USO_DISCO" -ge "$UMBRAL_DISCO" ] || [ "$USO_SWAP" -ge "$UMBRAL_SWAP" ] || [ "$MODO" = "--preview" ]; then
    CANDIDATOS=""
    TOTAL_ESTIMADO_KB=0

    JOURNAL_KB=$(du -sk /var/log/journal 2>/dev/null | awk '{print $1}')
    if [ -n "$JOURNAL_KB" ] && [ "$JOURNAL_KB" -gt 102400 ]; then
        JOURNAL_EXCESS_MB=$(( (JOURNAL_KB - 102400) / 1024 ))
        CANDIDATOS+="• *Journald:* ~${JOURNAL_EXCESS_MB} MB por encima del límite\n"
        TOTAL_ESTIMADO_KB=$(( TOTAL_ESTIMADO_KB + JOURNAL_KB - 102400 ))
    fi

    ARCHIVOS_BORRAR=$(find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.old" \) -mtime +${DIAS_LOGS})
    if [ -n "$ARCHIVOS_BORRAR" ]; then
        CANT_B=$(echo "$ARCHIVOS_BORRAR" | wc -l)
        SIZE_B_KB=$(echo "$ARCHIVOS_BORRAR" | xargs du -ck 2>/dev/null | tail -n1 | awk '{print $1}')
        SIZE_B_MB=$(( SIZE_B_KB / 1024 ))
        TOTAL_ESTIMADO_KB=$(( TOTAL_ESTIMADO_KB + SIZE_B_KB ))
        CANDIDATOS+="• *Logs rotados (${CANT_B} archivos / ~${SIZE_B_MB} MB):*\n"
        LISTA_B=$(echo "$ARCHIVOS_BORRAR" | head -n 8 | sed 's/^/   - /')
        CANDIDATOS+="${LISTA_B}\n"
        [ "$CANT_B" -gt 8 ] && CANDIDATOS+="   ...y $((CANT_B - 8)) más.\n"
    fi

    ARCHIVOS_TRUNCAR=$(find /var/log -type f -name "*.log" ! -path "$LOG_LOCAL" -size +50M)
    if [ -n "$ARCHIVOS_TRUNCAR" ]; then
        SIZE_T_KB=$(echo "$ARCHIVOS_TRUNCAR" | xargs du -ck 2>/dev/null | tail -n1 | awk '{print $1}')
        SIZE_T_MB=$(( SIZE_T_KB / 1024 ))
        TOTAL_ESTIMADO_KB=$(( TOTAL_ESTIMADO_KB + SIZE_T_KB ))
        CANDIDATOS+="• *Logs >50MB a vaciar (~${SIZE_T_MB} MB):*\n"
        LISTA_T=$(echo "$ARCHIVOS_TRUNCAR" | sed 's/^/   - /')
        CANDIDATOS+="${LISTA_T}\n"
    fi

    APT_KB=$(du -sk /var/cache/apt/archives 2>/dev/null | awk '{print $1}')
    APT_MB=$(( APT_KB / 1024 ))
    if [ "$APT_MB" -gt 5 ]; then
        TOTAL_ESTIMADO_KB=$(( TOTAL_ESTIMADO_KB + APT_KB ))
        CANDIDATOS+="• *Caché APT:* ~${APT_MB} MB\n"
    fi

    TOTAL_ESTIMADO_MB=$(( TOTAL_ESTIMADO_KB / 1024 ))

    MENSAJE="⚠️ *ALERTA DE ESPACIO Y LOGS*\n\n"
    [ "$MODO" = "--preview" ] && MENSAJE="🔍 *SIMULACIÓN DE ESPACIO Y LOGS*\n\n"
    MENSAJE+="🖥 *Servidor:* ${HOSTNAME}\n"
    MENSAJE+="📊 *Estado:* Disco ${USO_DISCO}% (${LIBRE_DISCO}/${TOTAL_DISCO}) | SWAP ${USO_SWAP}%\n\n"

    [ "$USO_DISCO" -ge "$UMBRAL_DISCO" ] && MENSAJE+="🚨 *Crítico:* Disco por encima del ${UMBRAL_DISCO}%\n"
    [ "$USO_SWAP" -ge "$UMBRAL_SWAP" ] && MENSAJE+="🚨 *Crítico:* SWAP por encima del ${UMBRAL_SWAP}%\n"

    if [ -n "$CANDIDATOS" ]; then
        MENSAJE+="\n📋 *Espacio recuperable (~${TOTAL_ESTIMADO_MB} MB estimados):*\n${CANDIDATOS}\n"
        MENSAJE+="👉 *Para ejecutar la limpieza en este servidor:*\n\`sudo /usr/local/bin/dskwap-guardian.sh --limpiar\`"
    else
        MENSAJE+="\nℹ️ _No hay archivos antiguos suficientes para limpiar._"
    fi

    enviar_telegram "$MENSAJE"
fi
