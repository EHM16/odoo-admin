#!/usr/bin/env bash

# ============================================================
# Odoo Admin
# Filesystem Backup
# ------------------------------------------------------------
# Version : 1.0
# ============================================================

set -uo pipefail

# ============================================================
# Información del Módulo
# ============================================================

readonly MODULE_NAME="backup-files"
readonly MODULE_DESCRIPTION="Filesystem Backup"
readonly MODULE_VERSION="1.0"

# ============================================================
# Bibliotecas
# ============================================================

source /opt/odoo-admin/scripts/logger.sh
source /opt/odoo-admin/scripts/fs.sh
source /opt/odoo-admin/scripts/config.sh
source /opt/odoo-admin/scripts/archive.sh

log_init

config_load_all
# ============================================================
# Configuración
# ============================================================

config_load system
config_load backup
config_load files

config_require \
    ODOO_CONFIG_DIR \
    ODOO_FILESTORE_DIR \
    ODOO_ADDONS_DIR \
    ODOO_ADMIN_DIR \
    BACKUP_ROOT \
    DAILY_DIR \
    WEEKLY_DIR \
    MONTHLY_DIR \
    TARGET_DIR \
    BACKUP_PREFIX \
    DATE_FORMAT \
    RETENTION_DAILY \
    RETENTION_WEEKLY \
    RETENTION_MONTHLY

# ============================================================
# Variables de Ejecución
# ============================================================

declare BACKUP_FILE=""

# ============================================================
# Inicio
# ============================================================

log_section "${PRODUCT_NAME} - ${MODULE_NAME}"

log_info "Producto : ${PRODUCT_NAME} ${PRODUCT_VERSION}"
log_info "Módulo   : ${MODULE_NAME} ${MODULE_VERSION}"

log_ok "Configuración cargada."

# ============================================================
# Verificación del Entorno
# ============================================================

check_environment() {

    log_section "Entorno"

    local resource
    local path

    while (( $# > 0 )); do

        resource="$1"
        path="$2"

        if ! fs_exists "$path"; then

            log_error "No existe el recurso."

            log_error "$resource : $path"

            exit 1

        fi

        shift 2

    done

    log_ok "Entorno verificado."

}

# ============================================================
# Verificación de Permisos
# ============================================================

check_permissions() {

    log_section "Permisos"

    log_info "Verificando directorio de respaldo..."

    if ! fs_is_writable "$TARGET_DIR"; then

        log_error "No es posible escribir en el directorio."

        log_error "$TARGET_DIR"

        exit 1

    fi

    log_ok "Permisos de escritura correctos."

}

# ============================================================
# Crear Respaldo
# ============================================================

create_backup() {

    log_section "Respaldo"

    BACKUP_FILE=$(
        fs_backup_filename \
            "$TARGET_DIR" \
            "$BACKUP_PREFIX" \
            "oaa" \
            "$DATE_FORMAT"
    ) || exit 1

    fs_mkdir "$TARGET_DIR" || {

        log_error "No fue posible crear el directorio de respaldo."

        exit 1

    }

    log_info "Directorio : $TARGET_DIR"
    log_info "Archivo    : $BACKUP_FILE"

    log_info "Iniciando respaldo..."

    archive_create \
        "$BACKUP_FILE" \
        config    "$ODOO_CONFIG_DIR" \
        filestore "$ODOO_FILESTORE_DIR" \
        addons    "$ODOO_ADDONS_DIR" \
        admin     "$ODOO_ADMIN_DIR" || {

        log_error "No fue posible generar el respaldo."

        exit 1

    }

    log_ok "Respaldo generado."

    log_info "Tamaño : $(numfmt --to=iec "$(fs_size "$BACKUP_FILE")")"

}

# ============================================================
# Rotación de Respaldos
# ============================================================

rotate_backups() {

    log_section "Rotación"

    if is_weekly_backup_day; then

        archive_backup \
            "$WEEKLY_DIR" \
            "Weekly" || exit 1

    else

        log_skip "Hoy no corresponde rotación semanal."

    fi

    if is_monthly_backup_day; then

        archive_backup \
            "$MONTHLY_DIR" \
            "Monthly" || exit 1

    else

        log_skip "Hoy no corresponde rotación mensual."

    fi

    log_ok "Rotación finalizada."

}

# ============================================================
# Archivar Respaldo
# ============================================================

archive_backup() {

    local destination="${1:-}"
    local label="${2:-}"

    [[ -n "$destination" && -n "$label" ]] || return 1

    log_info "Archivando respaldo en ${label}..."

    fs_copy \
    "$BACKUP_FILE" \
    "$destination" || {

    log_error "No fue posible archivar el respaldo."

    return 1

    }

    log_ok "Respaldo archivado en ${label}."

    return 0

}

# ============================================================
# Reglas de Calendario
# ============================================================

is_weekly_backup_day() {

    (( $(date +%u) == 7 ))

}

is_monthly_backup_day() {

    (( $(date +%d) == 1 ))

}

# ============================================================
# Retención de Respaldos
# ============================================================

prune_backups() {

    log_section "Retención"

    #
    # Respaldos diarios
    #

    log_info "Aplicando retención diaria..."

    fs_prune \
        "$DAILY_DIR" \
        "${BACKUP_PREFIX}_*.oaa" \
        "$RETENTION_DAILY" || {

        log_error "No fue posible aplicar la retención diaria."

        exit 1

    }

    #
    # Respaldos semanales
    #

    log_info "Aplicando retención semanal..."

    fs_prune \
        "$WEEKLY_DIR" \
        "${BACKUP_PREFIX}_*.oaa" \
        "$RETENTION_WEEKLY" || {

        log_error "No fue posible aplicar la retención semanal."

        exit 1

    }

    #
    # Respaldos mensuales
    #

    log_info "Aplicando retención mensual..."

    fs_prune \
        "$MONTHLY_DIR" \
        "${BACKUP_PREFIX}_*.oaa" \
        "$RETENTION_MONTHLY" || {

        log_error "No fue posible aplicar la retención mensual."

        exit 1

    }

    log_ok "Retención finalizada."

}

# ============================================================
# Programa Principal
# ============================================================

main() {

    log_section "${PRODUCT_NAME} - ${MODULE_NAME}"

    log_info "Producto : ${PRODUCT_NAME} ${PRODUCT_VERSION}"
    log_info "Módulo   : ${MODULE_NAME} ${MODULE_VERSION}"

    #
    # Verificación del Entorno
    #

    check_environment \
        config    "$ODOO_CONFIG_DIR" \
        filestore "$ODOO_FILESTORE_DIR" \
        addons    "$ODOO_ADDONS_DIR" \
        admin     "$ODOO_ADMIN_DIR"

    #
    # Verificación del Sistema
    #

    check_permissions

    #
    # Respaldo
    #

    create_backup

    #
    # Rotación
    #

    rotate_backups

    #
    # Retención
    #

    prune_backups

    log_ok "Backup completado correctamente."

    return 0

}

main "$@"