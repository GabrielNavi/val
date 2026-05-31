# shellcheck shell=bash
# val-common.sh — Funciones compartidas entre val y val-sub.
#
# Uso: source /usr/lib/val/val-common.sh
#
# El script que carga esta librería DEBE definir antes del source las
# variables que difieren por instancia (usando el patrón :- en los defaults):
#   LOG_TAG   → distinguir mensajes en journalctl ([VAL] o [NAME-VAL])
#   STATE_DIR → ruta de estado de la instancia
#   CONF_FILE → ruta al fichero de configuración principal
#   CONF_DIR  → directorio de overlays .conf.d
#   HOOKS_DIR → directorio de hooks (default: /etc/val/hooks.d)

# ---------------------------------------------------------------------------
# Rutas de estado
# ---------------------------------------------------------------------------
STATE_DIR="${STATE_DIR:-/var/lib/val}"
VERSION_FILE="${VERSION_FILE:-${STATE_DIR}/version}"
CLIENTS_FILE="${CLIENTS_FILE:-${STATE_DIR}/clients.json}"
TMP_CLIENTS="${TMP_CLIENTS:-${STATE_DIR}/clients.json.tmp}"

# ---------------------------------------------------------------------------
# Valores por defecto de configuración
# ---------------------------------------------------------------------------
SOURCE="${SOURCE:-vas}"
VAS_HOST="${VAS_HOST:-}"
VAS_SCHEME="${VAS_SCHEME:-http}"
VAC_STATE_DIR="${VAC_STATE_DIR:-/var/lib/vac}"
FILTER="${FILTER:-active}"
CHECK_SECONDS="${CHECK_SECONDS:-300}"
RETRY_SECONDS="${RETRY_SECONDS:-60}"
HOOKS_DIR="${HOOKS_DIR:-/etc/val/hooks.d}"
GLOBAL_KEY="${GLOBAL_KEY:-}"
LOCAL_KEY_LIST="${LOCAL_KEY_LIST:-}"
DISPATCH_STDIN="${DISPATCH_STDIN:-true}"
BUMP_LISTEN_PORT="${BUMP_LISTEN_PORT:-0}"
PARALLEL_MODE="${PARALLEL_MODE:-both}"
USE_VAT="${USE_VAT:-false}"
VAT_PRESET="${VAT_PRESET:-}"
HOOK_TIMEOUT_SECONDS="${HOOK_TIMEOUT_SECONDS:-30}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# LOG_LEVEL: no | normal | debug
# LOG_FILE:  vacío → solo stdout; ruta → también fichero con timestamp UTC.
# LOG_TAG:   prefijo de log; definir antes del source para cada instancia.
LOG_LEVEL="${LOG_LEVEL:-normal}"
LOG_FILE="${LOG_FILE:-}"
LOG_TAG="${LOG_TAG:-[VAL]}"

_log_write() {
    echo "$*"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

log() {
    [[ "$LOG_LEVEL" == "no" ]] && return 0
    _log_write "$LOG_TAG $*"
}

log_debug() {
    [[ "$LOG_LEVEL" != "debug" ]] && return 0
    _log_write "$LOG_TAG [DEBUG] $*"
}

# ---------------------------------------------------------------------------
# Carga de configuración
# ---------------------------------------------------------------------------
# Parser seguro: lee clave=valor sin ejecutar código del fichero.
# Solo acepta las variables conocidas; el resto se ignora silenciosamente.
load_conf() {
    local file="$1"
    [ -f "$file" ] || return 0

    local loaded=0
    while IFS='=' read -r key val; do
        key="$(echo "$key" | xargs 2>/dev/null || true)"
        val="$(echo "$val" | xargs 2>/dev/null | sed 's/^"//; s/"$//' || true)"
        [ -z "$key" ] && continue

        case "$key" in
            SOURCE)               SOURCE="$val";               (( ++loaded )) ;;
            VAS_HOST)             VAS_HOST="$val";             (( ++loaded )) ;;
            VAS_SCHEME)           VAS_SCHEME="$val";           (( ++loaded )) ;;
            VAC_STATE_DIR)        VAC_STATE_DIR="$val";        (( ++loaded )) ;;
            FILTER)               FILTER="$val";               (( ++loaded )) ;;
            CHECK_SECONDS)        CHECK_SECONDS="$val";        (( ++loaded )) ;;
            RETRY_SECONDS)        RETRY_SECONDS="$val";        (( ++loaded )) ;;
            HOOKS_DIR)            HOOKS_DIR="$val";            (( ++loaded )) ;;
            GLOBAL_KEY)           GLOBAL_KEY="$val";           (( ++loaded )) ;;
            LOCAL_KEY_LIST)       LOCAL_KEY_LIST="$val";       (( ++loaded )) ;;
            DISPATCH_STDIN)       DISPATCH_STDIN="$val";       (( ++loaded )) ;;
            BUMP_LISTEN_PORT)     BUMP_LISTEN_PORT="$val";     (( ++loaded )) ;;
            PARALLEL_MODE)        PARALLEL_MODE="$val";        (( ++loaded )) ;;
            USE_VAT)              USE_VAT="$val";              (( ++loaded )) ;;
            VAT_PRESET)           VAT_PRESET="$val";           (( ++loaded )) ;;
            HOOK_TIMEOUT_SECONDS) HOOK_TIMEOUT_SECONDS="$val"; (( ++loaded )) ;;
            LOG_LEVEL)            LOG_LEVEL="$val";            (( ++loaded )) ;;
            LOG_FILE)             LOG_FILE="$val";             (( ++loaded )) ;;
        esac
    done < <(grep -v '^\s*#' "$file" | grep '=' || true)

    log_debug "Config cargada desde $file: $loaded clave(s)"
}

# ---------------------------------------------------------------------------
# Normalización de VAS_HOST
# ---------------------------------------------------------------------------
_normalize_vas_host() {
    if [[ "$VAS_HOST" =~ ^(https?)://(.+) ]]; then
        local extracted="${BASH_REMATCH[1]}"
        VAS_HOST="${BASH_REMATCH[2]}"
        [[ "$extracted" != "$VAS_SCHEME" ]] && \
            log "[WARN] VAS_HOST contenía scheme '$extracted'; extraído a VAS_SCHEME. Usa VAS_SCHEME=$extracted en val.conf."
        VAS_SCHEME="$extracted"
    fi
    VAS_HOST="${VAS_HOST%/}"
    if [[ -n "$VAS_HOST" && ! "$VAS_HOST" =~ :[0-9]+$ ]]; then
        VAS_HOST="${VAS_HOST}:8000"
        log_debug "[CONFIG] Puerto implícito añadido: VAS_HOST=$VAS_HOST"
    fi
}

# ---------------------------------------------------------------------------
# Versión remota
# ---------------------------------------------------------------------------
get_remote_version() {
    local ver=""
    case "$SOURCE" in
        vas)
            ver="$(curl -fsS --max-time 10 --connect-timeout 5 \
                "${VAS_SCHEME}://${VAS_HOST}/version" 2>/dev/null \
                | jq -r '.version' 2>/dev/null \
                || echo "")"
            log_debug "[VERSION] Versión remota (VAS): ${ver:-(vacía)}"
            ;;
        vac)
            local vac_version="${VAC_STATE_DIR}/version"
            if [[ -f "$vac_version" ]]; then
                ver="$(tr -d '[:space:]' < "$vac_version")"
                log_debug "[VERSION] Versión remota (VAC fichero): ${ver:-(vacía)}"
            else
                log "[VERSION] Fichero VAC no encontrado: $vac_version"
            fi
            ;;
        *)
            log "[VERSION] SOURCE desconocido: '$SOURCE'. Valores válidos: vas, vac."
            ;;
    esac
    echo "$ver"
}

# ---------------------------------------------------------------------------
# Descarga de inventario
# ---------------------------------------------------------------------------
fetch_clients() {
    case "$SOURCE" in
        vas)
            local url="${VAS_SCHEME}://${VAS_HOST}/clients"
            local params=""
            [[ "$FILTER" != "active" ]] && params="status=${FILTER}"
            [[ -n "$GLOBAL_KEY" ]] && params="${params:+${params}&}extra_key=${GLOBAL_KEY}"
            [[ -n "$params" ]] && url="${url}?${params}"
            log "[FETCH] Descargando inventario desde $url"
            if curl -fsS --max-time 15 --connect-timeout 5 \
                "$url" -o "$TMP_CLIENTS" 2>/dev/null; then
                local count
                count="$(jq '.clients | length' "$TMP_CLIENTS" 2>/dev/null || echo '?')"
                mv "$TMP_CLIENTS" "$CLIENTS_FILE"
                log "[FETCH] Inventario guardado: $CLIENTS_FILE ($count equipo(s), filter=$FILTER)"
            else
                log "[VAL-ERROR] Error descargando inventario desde VAS. CLIENTS_FILE no modificado."
                rm -f "$TMP_CLIENTS"
                return 1
            fi
            ;;
        vac)
            local vac_clients="${VAC_STATE_DIR}/clients.json"
            if [[ -f "$vac_clients" ]]; then
                cp "$vac_clients" "$TMP_CLIENTS" && mv "$TMP_CLIENTS" "$CLIENTS_FILE"
                local count
                count="$(jq '.clients | length' "$CLIENTS_FILE" 2>/dev/null || echo '?')"
                log "[FETCH] Inventario copiado desde VAC: $CLIENTS_FILE ($count equipo(s))"
            else
                log "[VAL-ERROR] No se encontró ${vac_clients}. ¿Está VAC instalado y activo?"
                return 1
            fi
            ;;
    esac

    # VAT upstream: sanear clients.json antes de materializar y despachar.
    # Aplica a SOURCE=vas y SOURCE=vac por igual.
    if [[ "$USE_VAT" == "true" && -n "$VAT_PRESET" ]]; then
        if command -v vat-operate &>/dev/null; then
            local vat_out
            vat_out="$(vat-operate --source-component VAL --direction upstream \
                --preset "$VAT_PRESET" < "$CLIENTS_FILE" 2>/dev/null)" \
            && echo "$vat_out" > "${CLIENTS_FILE}.tmp" \
            && mv "${CLIENTS_FILE}.tmp" "$CLIENTS_FILE" \
            && log "[VAT] clients.json saneado (upstream) con preset '$VAT_PRESET'" \
            || log "[VAT-WARN] vat-operate falló. clients.json sin sanear."
        else
            log "[VAT-WARN] USE_VAT=true pero vat-operate no encontrado."
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Materialización de vistas por clave (LOCAL_KEY_LIST)
# ---------------------------------------------------------------------------
materialize_keys() {
    [[ -z "$LOCAL_KEY_LIST" ]] && return 0
    [[ ! -f "$CLIENTS_FILE" ]] && return 0

    for key in $LOCAL_KEY_LIST; do
        local out="${STATE_DIR}/${key}_clients.json"
        local tmp="${out}.tmp"
        if jq --arg key "$key" \
            '{clients: [.clients[]? | select(
                (.extra_imperative  and (.extra_imperative  | has($key))) or
                (.extra_informative and (.extra_informative | has($key)))
            )]}' \
            "$CLIENTS_FILE" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$out"
            # VAT downstream: sanear cada vista por clave antes de despachar a hooks.
            if [[ "$USE_VAT" == "true" && -n "$VAT_PRESET" ]]; then
                if command -v vat-operate &>/dev/null; then
                    local vat_out
                    vat_out="$(vat-operate --source-component VAL --direction downstream \
                        --preset "$VAT_PRESET" < "$out" 2>/dev/null)" \
                    && echo "$vat_out" > "${out}.tmp" \
                    && mv "${out}.tmp" "$out" \
                    && log "[VAT] ${key}_clients.json saneado (downstream) con preset '$VAT_PRESET'" \
                    || log "[VAT-WARN] vat-operate falló para ${key}_clients.json."
                else
                    log "[VAT-WARN] USE_VAT=true pero vat-operate no encontrado."
                fi
            fi

            local count
            count="$(jq '.clients | length' "$out" 2>/dev/null || echo '?')"
            log "[MATERIALIZE] ${key}_clients.json → $count equipo(s)"
        else
            log "[VAL-ERROR] Error materializando ${key}_clients.json"
            rm -f "$tmp"
        fi
    done
}

# ---------------------------------------------------------------------------
# Distribución a hooks
# ---------------------------------------------------------------------------
dispatch_hooks() {
    local version="$1"

    if [[ ! -d "$HOOKS_DIR" ]]; then
        log "[HOOKS] Directorio de hooks no encontrado: $HOOKS_DIR"
        return 0
    fi

    local hook_count=0
    local hook_errors=0

    local stdin_src="$CLIENTS_FILE"
    [[ "$DISPATCH_STDIN" != "true" ]] && stdin_src="/dev/null"

    local timeout_cmd=()
    [[ "$HOOK_TIMEOUT_SECONDS" != "0" ]] && timeout_cmd=(timeout "$HOOK_TIMEOUT_SECONDS")

    for hook in "$HOOKS_DIR"/*; do
        [[ -f "$hook" && -x "$hook" ]] || continue
        (( ++hook_count ))
        log "[HOOKS] Ejecutando: $(basename "$hook")"
        local hook_exit=0
        VAL_VERSION="$version" \
        VAL_FILTER="$FILTER" \
        VAL_SOURCE="$SOURCE" \
        VAL_EXTRA_KEY="$GLOBAL_KEY" \
        VAL_STATE_DIR="$STATE_DIR" \
        "${timeout_cmd[@]}" "$hook" < "$stdin_src" || hook_exit=$?
        if [[ $hook_exit -eq 0 ]]; then
            log "[HOOKS] OK: $(basename "$hook")"
        elif [[ $hook_exit -eq 124 ]]; then
            log "[VAL-ERROR] Hook $(basename "$hook") superó el timeout de ${HOOK_TIMEOUT_SECONDS}s."
            (( ++hook_errors ))
        else
            log "[VAL-ERROR] Hook $(basename "$hook") terminó con error ($hook_exit). Continuando."
            (( ++hook_errors ))
        fi
    done

    if [[ $hook_count -eq 0 ]]; then
        log "[HOOKS] Sin hooks ejecutables en $HOOKS_DIR"
    else
        log "[HOOKS] $hook_count hook(s) ejecutado(s), $hook_errors error(es)"
    fi
}

# ---------------------------------------------------------------------------
# Sleep interrumpible (VAL-Aware / bump listener)
# ---------------------------------------------------------------------------
interruptible_sleep() {
    if [[ "$BUMP_LISTEN_PORT" != "0" ]]; then
        read -t "$1" -r _bump <&3 2>/dev/null || true
    else
        sleep "$1"
    fi
}

# ---------------------------------------------------------------------------
# Escritura atómica del fichero de versión local
# ---------------------------------------------------------------------------
write_version() {
    local ver="$1" tmp="${VERSION_FILE}.tmp"
    echo "$ver" > "$tmp" && mv "$tmp" "$VERSION_FILE" \
        || { rm -f "$tmp"; log "[WARN] No se pudo escribir VERSION_FILE."; }
}
