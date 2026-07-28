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

readonly BACKUP_STATUS_OK="OK"
readonly BACKUP_STATUS_ERROR="ERROR"
readonly BACKUP_STATUS_NOT_RUN="NOT_RUN"

readonly BACKUP_RESULT_COMPLETE="COMPLETE"
readonly BACKUP_RESULT_FAILED="FAILED"
readonly BACKUP_RESULT_PARTIAL="PARTIAL"
readonly BACKUP_RESULT_REJECTED="REJECTED"
readonly BACKUP_RESULT_INTERNAL_ERROR="INTERNAL_ERROR"

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
declare ACTIVE_CHILD_PID=""
declare RECEIVED_SIGNAL=""
declare DB_STATUS="$BACKUP_STATUS_NOT_RUN"
declare FILES_STATUS="$BACKUP_STATUS_NOT_RUN"
declare DB_DURATION="$BACKUP_STATUS_NOT_RUN"
declare FILES_DURATION="$BACKUP_STATUS_NOT_RUN"

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
    local total_duration="${3:-}"

    log_section "Backup Summary"
    log_key_value "Database" "$DB_STATUS"
    log_key_value "Filesystem" "$FILES_STATUS"
    log_key_value "Database duration" "$DB_DURATION"
    log_key_value "Filesystem duration" "$FILES_DURATION"
    log_key_value "Total duration" "$total_duration"
    log_key_value "Result" "$result"
    log_key_value "Exit code" "$exit_code"

}

_backup_signal_number() {

    case "${1:-}" in
        HUP) printf '%s' 1 ;;
        INT) printf '%s' 2 ;;
        TERM) printf '%s' 15 ;;
        *) return 1 ;;
    esac

}

_backup_handle_signal() {

    local signal="${1:-}"
    [[ -z "$RECEIVED_SIGNAL" ]] || return
    RECEIVED_SIGNAL="$signal"
    trap - HUP INT TERM

    log_warn "Backup job interrupted by signal ${signal}."

    if [[ -n "$ACTIVE_CHILD_PID" ]]; then
        # Each asynchronous component is its own process-group leader. Forward
        # to that group so the script and all descendants receive the signal,
        # without touching unrelated processes.
        kill -s "$signal" -- "-${ACTIVE_CHILD_PID}" 2>/dev/null || true
    fi

}

_backup_install_signal_handlers() {

    trap '_backup_handle_signal HUP' HUP
    trap '_backup_handle_signal INT' INT
    trap '_backup_handle_signal TERM' TERM

}

_backup_validate_components() {

    if ! command -v setsid >/dev/null 2>&1; then
        log_error "Required process-group utility is unavailable: setsid"
        return 1
    fi

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
    local child_status
    local signal_number

    [[ -n "$component" ]] || return 1

    # setsid (from util-linux, already required for flock) isolates the
    # asynchronous component in a dedicated session and process group.
    # ACTIVE_CHILD_PID is therefore both the child PID and its PGID.
    setsid --wait "$component" &
    ACTIVE_CHILD_PID=$!

    wait "$ACTIVE_CHILD_PID"
    child_status=$?

    if [[ -n "$RECEIVED_SIGNAL" ]]; then
        # Waiting again outside the trap avoids nesting wait on the same Bash
        # job while still ensuring the signalled process group has terminated.
        wait "$ACTIVE_CHILD_PID" 2>/dev/null || true
        ACTIVE_CHILD_PID=""
        signal_number=$(_backup_signal_number "$RECEIVED_SIGNAL") ||
            exit "$BACKUP_EXIT_INTERNAL"
        exit "$(( 128 + signal_number ))"
    fi

    ACTIVE_CHILD_PID=""

    return "$child_status"

}

main() {

    local start_time
    local end_time
    local duration
    local lock_status
    local exit_code
    local result
    local component_start
    local component_end

    start_time=$SECONDS

    if ! _backup_bootstrap; then
        printf 'backup: orchestrator initialization failed\n' >&2
        return "$BACKUP_EXIT_INTERNAL"
    fi

    # Traps are deliberately installed only after the logger is initialized.
    _backup_install_signal_handlers

    log_section "${PRODUCT_NAME} - ${MODULE_NAME}"
    log_info "Product : ${PRODUCT_NAME} ${PRODUCT_VERSION}"
    log_info "Module  : ${MODULE_NAME} ${MODULE_VERSION}"

    _backup_validate_components || {
        end_time=$SECONDS
        duration=$(_backup_format_duration "$(( end_time - start_time ))")
        _backup_log_summary "$BACKUP_RESULT_INTERNAL_ERROR" "$BACKUP_EXIT_INTERNAL" "$duration"
        return "$BACKUP_EXIT_INTERNAL"
    }

    fs_lock_acquire "$BACKUP_LOCK_FILE" BACKUP_LOCK_FD
    lock_status=$?

    if (( lock_status == 1 )); then
        end_time=$SECONDS
        duration=$(_backup_format_duration "$(( end_time - start_time ))")
        log_warn "Another backup job is already running."
        _backup_log_summary "$BACKUP_RESULT_REJECTED" "$BACKUP_EXIT_LOCKED" "$duration"
        return "$BACKUP_EXIT_LOCKED"
    elif (( lock_status != 0 )); then
        end_time=$SECONDS
        duration=$(_backup_format_duration "$(( end_time - start_time ))")
        log_error "The backup lock could not be initialized: ${BACKUP_LOCK_FILE}"
        _backup_log_summary "$BACKUP_RESULT_INTERNAL_ERROR" "$BACKUP_EXIT_INTERNAL" "$duration"
        return "$BACKUP_EXIT_INTERNAL"
    fi

    # BACKUP_LOCK_FD must remain open until the active child has terminated.
    # The lock is released automatically at process exit; the lock file itself
    # intentionally remains and no explicit unlock is required.
    component_start=$SECONDS
    if _backup_run_component "$BACKUP_DB_SCRIPT"; then
        DB_STATUS="$BACKUP_STATUS_OK"
    else
        DB_STATUS="$BACKUP_STATUS_ERROR"
    fi
    component_end=$SECONDS
    DB_DURATION=$(_backup_format_duration "$(( component_end - component_start ))")

    component_start=$SECONDS
    if _backup_run_component "$BACKUP_FILES_SCRIPT"; then
        FILES_STATUS="$BACKUP_STATUS_OK"
    else
        FILES_STATUS="$BACKUP_STATUS_ERROR"
    fi
    component_end=$SECONDS
    FILES_DURATION=$(_backup_format_duration "$(( component_end - component_start ))")

    if [[ "$DB_STATUS" == "$BACKUP_STATUS_OK" && "$FILES_STATUS" == "$BACKUP_STATUS_OK" ]]; then
        result="$BACKUP_RESULT_COMPLETE"
        exit_code=$BACKUP_EXIT_COMPLETE
    elif [[ "$DB_STATUS" == "$BACKUP_STATUS_ERROR" && "$FILES_STATUS" == "$BACKUP_STATUS_ERROR" ]]; then
        result="$BACKUP_RESULT_FAILED"
        exit_code=$BACKUP_EXIT_FAILED
    else
        result="$BACKUP_RESULT_PARTIAL"
        exit_code=$BACKUP_EXIT_PARTIAL
    fi

    end_time=$SECONDS
    duration=$(_backup_format_duration "$(( end_time - start_time ))")
    _backup_log_summary "$result" "$exit_code" "$duration"

    return "$exit_code"

}

main "$@"
