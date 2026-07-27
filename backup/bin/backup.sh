#!/usr/bin/env bash

# ============================================================
# Odoo Admin
# Backup Job Orchestrator
# ------------------------------------------------------------
# Version : 1.0
# ============================================================

set -uo pipefail

readonly MODULE_NAME="backup"
readonly MODULE_DESCRIPTION="Backup Job Orchestrator"
readonly MODULE_VERSION="1.0"

readonly BACKUP_EXIT_COMPLETE=0
readonly BACKUP_EXIT_FAILED=1
readonly BACKUP_EXIT_PARTIAL=2
readonly BACKUP_EXIT_LOCKED=3
readonly BACKUP_EXIT_INTERNAL=4

readonly SCRIPT_DIRECTORY=$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
)
readonly ODOO_ADMIN_ROOT=$(
    cd -- "${SCRIPT_DIRECTORY}/../.." && pwd
)

readonly BACKUP_DB_SCRIPT="${BACKUP_DB_SCRIPT:-${SCRIPT_DIRECTORY}/backup-db.sh}"
readonly BACKUP_FILES_SCRIPT="${BACKUP_FILES_SCRIPT:-${SCRIPT_DIRECTORY}/backup-files.sh}"

readonly LOGGER_LIBRARY="${ODOO_ADMIN_ROOT}/scripts/logger.sh"
readonly FS_LIBRARY="${ODOO_ADMIN_ROOT}/scripts/fs.sh"
readonly CONFIG_LIBRARY="${ODOO_ADMIN_ROOT}/scripts/config.sh"

declare BACKUP_LOCK_FD=""
declare DB_STATUS="NOT_RUN"
declare FILES_STATUS="NOT_RUN"

_backup_bootstrap() {

    CONFIG_DIRECTORY="${CONFIG_DIRECTORY:-${ODOO_ADMIN_ROOT}/config}"

    [[ -r "$LOGGER_LIBRARY" ]] || return 1
    [[ -r "$FS_LIBRARY" ]] || return 1
    [[ -r "$CONFIG_LIBRARY" ]] || return 1

    # shellcheck source=../../scripts/logger.sh
    source "$LOGGER_LIBRARY" || return 1
    # shellcheck source=../../scripts/fs.sh
    source "$FS_LIBRARY" || return 1
    # shellcheck source=../../scripts/config.sh
    source "$CONFIG_LIBRARY" || return 1

    log_init || return 1
    config_load system || return 1
    config_load backup || return 1
    config_require BACKUP_LOCK_FILE || return 1

    return 0

}

_backup_format_duration() {

    local total_seconds="${1:-}"

    [[ "$total_seconds" =~ ^[0-9]+$ ]] || return 1

    printf '%02d:%02d:%02d' \
        "$(( total_seconds / 3600 ))" \
        "$(( total_seconds % 3600 / 60 ))" \
        "$(( total_seconds % 60 ))"

}

_backup_log_summary() {

    local result="${1:-}"
    local exit_code="${2:-}"
    local duration="${3:-}"

    log_section "Backup Summary"
    log_info "Database ........ ${DB_STATUS}"
    log_info "Filesystem ...... ${FILES_STATUS}"
    log_info "Duration ........ ${duration}"
    log_info "Result .......... ${result}"
    log_info "Exit code ....... ${exit_code}"

}

_backup_validate_components() {

    if [[ ! -f "$BACKUP_DB_SCRIPT" || ! -x "$BACKUP_DB_SCRIPT" ]]; then
        log_error "Database backup component is unavailable: ${BACKUP_DB_SCRIPT}"
        return 1
    fi

    if [[ ! -f "$BACKUP_FILES_SCRIPT" || ! -x "$BACKUP_FILES_SCRIPT" ]]; then
        log_error "Filesystem backup component is unavailable: ${BACKUP_FILES_SCRIPT}"
        return 1
    fi

    return 0

}

_backup_run_component() {

    local component="${1:-}"

    [[ -n "$component" ]] || return 1
    "$component"

}

main() {

    local start_time
    local end_time
    local duration
    local lock_status
    local exit_code
    local result

    start_time=$(date +%s)

    if ! _backup_bootstrap; then
        printf 'backup: orchestrator initialization failed\n' >&2
        return "$BACKUP_EXIT_INTERNAL"
    fi

    log_section "${PRODUCT_NAME} - ${MODULE_NAME}"
    log_info "Product : ${PRODUCT_NAME} ${PRODUCT_VERSION}"
    log_info "Module  : ${MODULE_NAME} ${MODULE_VERSION}"

    _backup_validate_components || {
        end_time=$(date +%s)
        duration=$(_backup_format_duration "$(( end_time - start_time ))")
        _backup_log_summary "INTERNAL_ERROR" "$BACKUP_EXIT_INTERNAL" "$duration"
        return "$BACKUP_EXIT_INTERNAL"
    }

    fs_lock_acquire "$BACKUP_LOCK_FILE" BACKUP_LOCK_FD
    lock_status=$?

    if (( lock_status == 1 )); then
        end_time=$(date +%s)
        duration=$(_backup_format_duration "$(( end_time - start_time ))")
        log_warn "Another backup job is already running."
        _backup_log_summary "REJECTED" "$BACKUP_EXIT_LOCKED" "$duration"
        return "$BACKUP_EXIT_LOCKED"
    elif (( lock_status != 0 )); then
        end_time=$(date +%s)
        duration=$(_backup_format_duration "$(( end_time - start_time ))")
        log_error "The backup lock could not be initialized: ${BACKUP_LOCK_FILE}"
        _backup_log_summary "INTERNAL_ERROR" "$BACKUP_EXIT_INTERNAL" "$duration"
        return "$BACKUP_EXIT_INTERNAL"
    fi

    if _backup_run_component "$BACKUP_DB_SCRIPT"; then
        DB_STATUS="OK"
    else
        DB_STATUS="ERROR"
    fi

    if _backup_run_component "$BACKUP_FILES_SCRIPT"; then
        FILES_STATUS="OK"
    else
        FILES_STATUS="ERROR"
    fi

    if [[ "$DB_STATUS" == "OK" && "$FILES_STATUS" == "OK" ]]; then
        result="COMPLETE"
        exit_code=$BACKUP_EXIT_COMPLETE
    elif [[ "$DB_STATUS" == "ERROR" && "$FILES_STATUS" == "ERROR" ]]; then
        result="FAILED"
        exit_code=$BACKUP_EXIT_FAILED
    else
        result="PARTIAL"
        exit_code=$BACKUP_EXIT_PARTIAL
    fi

    end_time=$(date +%s)
    duration=$(_backup_format_duration "$(( end_time - start_time ))")
    _backup_log_summary "$result" "$exit_code" "$duration"

    return "$exit_code"

}

main "$@"
