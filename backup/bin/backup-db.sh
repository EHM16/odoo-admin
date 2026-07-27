# ============================================================
# Información del Módulo
# ============================================================

readonly MODULE_NAME="backup-db"
readonly MODULE_DESCRIPTION="Database Backup"
readonly MODULE_VERSION="1.0"

# ============================================================
# Bibliotecas
# ============================================================

source /opt/odoo-admin/scripts/logger.sh
source /opt/odoo-admin/scripts/fs.sh
source /opt/odoo-admin/scripts/config.sh
source /opt/odoo-admin/scripts/pg.sh

log_init

config_load_all
# ============================================================
# Configuración
# ============================================================

config_require \
    DB_NAME \
    DB_HOST \
    DB_PORT \
    DB_USER \
    DB_PASSWORD \
    PSQL \
    PG_DUMP \
    PG_RESTORE \
    BACKUP_ROOT \
    DAILY_DIR \
    WEEKLY_DIR \
    MONTHLY_DIR \
    TARGET_DIR \
    BACKUP_PREFIX \
    BACKUP_FORMAT \
    DATE_FORMAT \
    SPACE_FACTOR \
    COMPRESSION_LEVEL \
    RETENTION_DAILY \
    RETENTION_WEEKLY \
    RETENTION_MONTHLY

# ============================================================
# Variables de Ejecución
# ============================================================

declare BACKUP_FILE=""

# ============================================================
# Verificación del Entorno
# ============================================================

check_environment() {

    log_section "Entorno"

    if ! pg_check_environment "$DB_NAME"; then

        log_error "Entorno PostgreSQL inválido."

        exit 1

    fi

    log_ok "Entorno PostgreSQL verificado."

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
# Verificación de Espacio en Disco
# ============================================================

check_disk_space() {

    log_section "Espacio en Disco"

    local database_size
    local available
    local required

    database_size=$(pg_database_size "$DB_NAME")

    available=$(
        df \
            --output=avail \
            -B1 \
            "$TARGET_DIR" \
        | tail -1
    )

    required=$(( database_size * SPACE_FACTOR ))

    log_info "Base de datos : $(numfmt --to=iec "$database_size")"
    log_info "Disponible    : $(numfmt --to=iec "$available")"
    log_info "Requerido     : $(numfmt --to=iec "$required")"

    if (( available < required )); then

        log_error "Espacio insuficiente para realizar el respaldo."

        exit 1

    fi

    log_ok "Espacio suficiente."

}

# ============================================================
# Respaldo de Base de Datos
# ============================================================

backup_database() {

    log_section "Respaldo"

    local backup_size

    BACKUP_FILE=$(
        fs_backup_filename \
            "$TARGET_DIR" \
            "$BACKUP_PREFIX" \
            "dump" \
            "$DATE_FORMAT"
    ) || exit 1

    fs_mkdir "$TARGET_DIR" || exit 1

    log_info "Directorio : $TARGET_DIR"
    log_info "Archivo    : $BACKUP_FILE"

    log_info "Iniciando respaldo..."

    pg_backup \
        "$DB_NAME" \
        "$BACKUP_FILE" \
        "$COMPRESSION_LEVEL" || {

        log_error "No fue posible generar el respaldo."

        exit 1

    }

    backup_size=$(numfmt --to=iec "$(fs_size "$BACKUP_FILE")")

    log_ok "Respaldo generado."

    log_info "Tamaño : $backup_size"

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
# Retención de Respaldos
# ============================================================

prune_backups() {

    log_section "Retención"

    log_info "Aplicando retención diaria..."

    fs_prune \
        "$DAILY_DIR" \
        "${BACKUP_PREFIX}_*.dump" \
        "$RETENTION_DAILY" || exit 1

    log_info "Aplicando retención semanal..."

    fs_prune \
        "$WEEKLY_DIR" \
        "${BACKUP_PREFIX}_*.dump" \
        "$RETENTION_WEEKLY" || exit 1

    log_info "Aplicando retención mensual..."

    fs_prune \
        "$MONTHLY_DIR" \
        "${BACKUP_PREFIX}_*.dump" \
        "$RETENTION_MONTHLY" || exit 1

    log_ok "Retención finalizada."

}

# ============================================================
# Programa Principal
# ============================================================

main() {

    log_section "${PRODUCT_NAME} - ${MODULE_NAME}"

    log_info "Producto : ${PRODUCT_NAME} ${PRODUCT_VERSION}"
    log_info "Módulo   : ${MODULE_NAME} ${MODULE_VERSION}"
    log_ok "Configuración cargada."

    #
    # Verificación del Entorno
    #

    check_environment

    #
    # Verificación del Sistema
    #

    check_permissions

    check_disk_space

    #
    # Respaldo
    #

    backup_database

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