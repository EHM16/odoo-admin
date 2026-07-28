#!/usr/bin/env bash

# ============================================================
# Odoo Admin
# Logger Library
# ------------------------------------------------------------
# Version : 1.0
# ============================================================

set -uo pipefail

# ============================================================
# Configuración
# ============================================================

LOG_DIRECTORY="${LOG_DIRECTORY:-/opt/odoo-admin/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIRECTORY}/odoo-admin.log}"
LOG_DATE_FORMAT="${LOG_DATE_FORMAT:-%Y-%m-%d %H:%M:%S}"

# ============================================================
# Constantes
# ============================================================

readonly LOG_SEPARATOR="============================================================"
readonly LOG_KEY_WIDTH=25

readonly LOG_LEVEL_INFO="INFO"
readonly LOG_LEVEL_OK="OK"
readonly LOG_LEVEL_WARN="WARN"
readonly LOG_LEVEL_ERROR="ERROR"
readonly LOG_LEVEL_SKIP="SKIP"

# ============================================================
# Colores ANSI
# ============================================================

readonly COLOR_RESET="\033[0m"

readonly COLOR_INFO="\033[1;34m"
readonly COLOR_OK="\033[1;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[1;31m"
readonly COLOR_SKIP="\033[1;36m"

# ============================================================
# Inicialización
# ============================================================

log_init() {

    mkdir -p "$LOG_DIRECTORY"

    touch "$LOG_FILE" 2>/dev/null || true

}

# ============================================================
# Funciones Privadas
# ============================================================

_use_color() {

    [[ -t 1 ]]

}

_timestamp() {

    date +"$LOG_DATE_FORMAT"

}

_get_color() {

    local level="$1"

    case "$level" in

        "$LOG_LEVEL_INFO")  printf "%s" "$COLOR_INFO" ;;

        "$LOG_LEVEL_OK")    printf "%s" "$COLOR_OK" ;;

        "$LOG_LEVEL_WARN")  printf "%s" "$COLOR_WARN" ;;

        "$LOG_LEVEL_ERROR") printf "%s" "$COLOR_ERROR" ;;

        "$LOG_LEVEL_SKIP")  printf "%s" "$COLOR_SKIP" ;;

        *)                  printf "%s" "$COLOR_RESET" ;;

    esac

}

_write_log() {

    printf "%s\n" "$1" >> "$LOG_FILE" 2>/dev/null || true

}

_console() {

    local level="$1"
    local message="$2"

    if _use_color; then

        printf "%b[ %-5s ]%b %s\n" \
            "$(_get_color "$level")" \
            "$level" \
            "$COLOR_RESET" \
            "$message"

    else

        printf "[ %-5s ] %s\n" \
            "$level" \
            "$message"

    fi

}

_log() {

    local level="$1"

    shift

    local message="$*"

    local timestamp

    timestamp=$(_timestamp)

    _console "$level" "$message"

    _write_log \
        "$timestamp [ $(printf "%-5s" "$level") ] $message"

}

# ============================================================
# API Pública
# ============================================================

#
# Niveles
#

log_info() {

    _log "$LOG_LEVEL_INFO" "$@"

}

log_ok() {

    _log "$LOG_LEVEL_OK" "$@"

}

log_warn() {

    _log "$LOG_LEVEL_WARN" "$@"

}

log_error() {

    _log "$LOG_LEVEL_ERROR" "$@"

}

log_skip() {

    _log "$LOG_LEVEL_SKIP" "$@"

}

#
# Utilidades
#

log_key_value() {

    local key="${1:-}"
    local value="${2:-}"
    local padding
    local padding_width

    (( $# == 2 )) || return 1
    [[ -n "$key" && -n "$value" ]] || return 1

    padding_width=$(( LOG_KEY_WIDTH - ${#key} ))
    (( padding_width < 1 )) && padding_width=1
    printf -v padding '%*s' "$padding_width" ''
    padding=${padding// /.}

    log_info "${key} ${padding} ${value}"

}

log_blank() {

    printf "\n"

    _write_log ""

}

log_section() {

    local title="$1"

    local timestamp

    timestamp=$(_timestamp)

    printf "\n"

    printf "%s\n" "$LOG_SEPARATOR"

    printf "%s\n" "$title"

    printf "%s\n" "$LOG_SEPARATOR"

    printf "\n"

    _write_log ""

    _write_log "$LOG_SEPARATOR"

    _write_log "$timestamp"

    _write_log "$title"

    _write_log "$LOG_SEPARATOR"

}

# ============================================================
# Inicialización
# ============================================================

log_init() {

    mkdir -p "$LOG_DIRECTORY"
    touch "$LOG_FILE" 2>/dev/null || true

}
