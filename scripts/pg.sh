#!/usr/bin/env bash

# ============================================================
# Odoo Admin
# PostgreSQL Library
# ------------------------------------------------------------
# Version : 1.0
# ============================================================

set -uo pipefail

# ============================================================
# Funciones Privadas
# ============================================================

_pg_check_arguments() {

    local argument

    for argument in "$@"; do

        [[ -n "$argument" ]] || return 1

    done

    return 0

}

_pg_psql() {

    PGPASSWORD="$DB_PASSWORD" \
    "$PSQL" \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        "$@"

}

_pg_dump() {

    PGPASSWORD="$DB_PASSWORD" \
    "$PG_DUMP" \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        "$@"

}

_pg_restore() {

    PGPASSWORD="$DB_PASSWORD" \
    "$PG_RESTORE" \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        "$@"

}

# ============================================================
# Consultas Administrativas
# ============================================================

_pg_admin_query() {

    local query="${1:-}"

    _pg_check_arguments "$query" || return 1

    pg_query \
    postgres \
    "$query"

}

# ============================================================
# Conectividad
# ============================================================

pg_is_available() {

    _pg_psql \
        -d postgres \
        -c "SELECT 1;" \
        >/dev/null 2>&1

}

pg_query() {

    local database="${1:-}"
    local query="${2:-}"

    _pg_check_arguments \
        "$database" \
        "$query" || return 1

    _pg_psql \
        -d "$database" \
        -tAc "$query"

}

pg_execute() {

    local database="${1:-}"
    local query="${2:-}"

    _pg_check_arguments \
        "$database" \
        "$query" || return 1

    _pg_psql \
        -d "$database" \
        -c "$query" \
        >/dev/null

}

pg_check_environment() {

    local database="${1:-}"

    _pg_check_arguments "$database" || return 1

    #
    # Verificar servidor PostgreSQL
    #

    pg_is_available || return 1

    #
    # Verificar base de datos
    #

    pg_database_exists "$database" || return 1

    return 0

}

# ============================================================
# Base de Datos
# ============================================================

pg_database_exists() {

    local database="${1:-}"

    _pg_check_arguments "$database" || return 1

    _pg_admin_query \
        "SELECT 1
           FROM pg_database
          WHERE datname='${database}';" \
    | grep -q '^1$'

}

pg_database_size() {

    local database="${1:-}"

    _pg_check_arguments "$database" || return 1

    _pg_admin_query \
        "SELECT pg_database_size('${database}');"

}

pg_database_list() {

    _pg_admin_query \
        "SELECT datname
           FROM pg_database
          WHERE datistemplate = false
          ORDER BY datname;"

}

pg_database_count() {

    _pg_admin_query \
        "SELECT COUNT(*)
           FROM pg_database
          WHERE datistemplate = false;"

}

# ============================================================
# Respaldos
# ============================================================

pg_backup() {

    local database="${1:-}"
    local output="${2:-}"
    local compression="${3:-6}"

    _pg_check_arguments \
        "$database" \
        "$output" || return 1

    _pg_dump \
        -F C \
        -Z "$compression" \
        -f "$output" \
        "$database"

    [[ -f "$output" ]]

}

pg_restore_database() {

    local database="${1:-}"
    local backup_file="${2:-}"

    _pg_check_arguments \
        "$database" \
        "$backup_file" || return 1

    [[ -f "$backup_file" ]] || return 1

    _pg_restore \
        -d "$database" \
        "$backup_file"

}

# ============================================================
# Información
# ============================================================

pg_version() {

    _pg_admin_query \
        "SELECT version();"

}