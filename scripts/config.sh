#!/usr/bin/env bash

# ============================================================
# Odoo Admin
# Configuration Library
# ------------------------------------------------------------
# Version : 1.0
# ============================================================

set -uo pipefail

# ============================================================
# Configuración
# ============================================================

readonly CONFIG_DIRECTORY="/opt/odoo-admin/config"

# ============================================================
# Funciones Privadas
# ============================================================

_config_check_arguments() {

    local argument

    for argument in "$@"; do

        [[ -n "$argument" ]] || return 1

    done

    return 0

}

_config_file() {

    local module="${1:-}"

    _config_check_arguments "$module" || return 1

    printf "%s/%s.conf" \
        "$CONFIG_DIRECTORY" \
        "$module"

}

# ============================================================
# API Pública
# ============================================================

config_exists() {

    local module="${1:-}"

    _config_check_arguments "$module" || return 1

    [[ -f "$(_config_file "$module")" ]]

}

config_load() {

    local module="${1:-}"
    local file

    _config_check_arguments "$module" || return 1

    file="$(_config_file "$module")"

    [[ -f "$file" ]] || return 1

    source "$file"

}

config_load_all() {

    config_load system    || return 1
    config_load postgres  || return 1
    config_load backup    || return 1

    return 0

}

config_require() {

    local variable

    for variable in "$@"; do

        [[ -n "${!variable:-}" ]] || return 1

    done

    return 0

}