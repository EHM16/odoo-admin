#!/usr/bin/env bash

set -uo pipefail

readonly TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly ORCHESTRATOR="${TEST_ROOT}/backup/bin/backup.sh"

declare TEST_DIRECTORY=""
declare TEST_COUNT=0

fail() {
    printf 'not ok %d - %s\n' "$TEST_COUNT" "$1" >&2
    exit 1
}

pass() {
    printf 'ok %d - %s\n' "$TEST_COUNT" "$1"
}

run_test() {
    local description="$1"

    shift
    TEST_COUNT=$(( TEST_COUNT + 1 ))
    "$@" || fail "$description"
    pass "$description"
}

setup() {
    TEST_DIRECTORY=$(mktemp -d)
    trap 'rm -rf -- "$TEST_DIRECTORY"' EXIT
}

make_component() {
    local path="$1"
    local status="$2"
    local marker="${3:-}"

    mkdir -p "$(dirname -- "$path")"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -uo pipefail'
        if [[ -n "$marker" ]]; then
            printf 'printf "run\\n" >> %q\n' "$marker"
        fi
        printf 'exit %q\n' "$status"
    } > "$path"
    chmod +x "$path"
}

run_orchestrator() {
    local db_script="$1"
    local files_script="$2"
    local lock_file="$3"
    local output_file="$4"

    LOG_DIRECTORY="${TEST_DIRECTORY}/logs" \
    BACKUP_DB_SCRIPT="$db_script" \
    BACKUP_FILES_SCRIPT="$files_script" \
    BACKUP_LOCK_FILE="$lock_file" \
        "$ORCHESTRATOR" >"$output_file" 2>&1
}

test_result_matrix() {
    local case_directory="${TEST_DIRECTORY}/matrix"
    local db_script="${case_directory}/database job"
    local files_script="${case_directory}/filesystem job"
    local output="${case_directory}/output"
    local marker="${case_directory}/runs"
    local expected
    local db_status
    local files_status
    local status

    mkdir -p "$case_directory"

    for db_status in 0 7; do
        for files_status in 0 8; do
            : > "$marker"
            make_component "$db_script" "$db_status" "$marker"
            make_component "$files_script" "$files_status" "$marker"

            if (( db_status == 0 && files_status == 0 )); then
                expected=0
            elif (( db_status != 0 && files_status != 0 )); then
                expected=1
            else
                expected=2
            fi

            set +e
            (
                cd /
                run_orchestrator \
                    "$db_script" \
                    "$files_script" \
                    "${case_directory}/job lock" \
                    "$output"
            )
            status=$?
            set -e

            [[ "$status" == "$expected" ]] || return 1
            [[ $(wc -l < "$marker") == 2 ]] || return 1
            grep -Eq "Exit code \\. +${expected}$|Exit code \\.+ ${expected}$" "$output" || return 1
            grep -Eq 'Database duration \.+ [0-9]{2}:[0-9]{2}:[0-9]{2}' "$output" || return 1
            grep -Eq 'Filesystem duration \.+ [0-9]{2}:[0-9]{2}:[0-9]{2}' "$output" || return 1
            grep -Eq 'Total duration \.+ [0-9]{2}:[0-9]{2}:[0-9]{2}' "$output" || return 1
        done
    done
}

test_summary_states() {
    local directory="${TEST_DIRECTORY}/summary"
    local db_script="${directory}/db"
    local files_script="${directory}/files"
    local output="${directory}/output"
    local status

    make_component "$db_script" 9
    make_component "$files_script" 0

    set +e
    run_orchestrator "$db_script" "$files_script" "${directory}/lock" "$output"
    status=$?
    set -e

    [[ "$status" == 2 ]] &&
        grep -Eq 'Database \.+ ERROR' "$output" &&
        grep -Eq 'Filesystem \.+ OK' "$output" &&
        grep -Eq 'Database duration \.+ [0-9]{2}:[0-9]{2}:[0-9]{2}' "$output" &&
        grep -Eq 'Filesystem duration \.+ [0-9]{2}:[0-9]{2}:[0-9]{2}' "$output" &&
        grep -Eq 'Result \.+ PARTIAL' "$output"
}

test_missing_components_are_internal_error() {
    local directory="${TEST_DIRECTORY}/missing"
    local files_script="${directory}/files"
    local output="${directory}/output"
    local status

    make_component "$files_script" 0

    set +e
    run_orchestrator \
        "${directory}/does not exist" \
        "$files_script" \
        "${directory}/lock" \
        "$output"
    status=$?
    set -e

    [[ "$status" == 4 ]] &&
        grep -Eq 'Database \.+ NOT_RUN' "$output" &&
        grep -Eq 'Filesystem \.+ NOT_RUN' "$output" &&
        grep -Eq 'Database duration \.+ NOT_RUN' "$output" &&
        grep -Eq 'Filesystem duration \.+ NOT_RUN' "$output" &&
        grep -Eq 'Result \.+ INTERNAL_ERROR' "$output"
}

test_lock_error_is_internal() {
    local directory="${TEST_DIRECTORY}/lock-error"
    local db_script="${directory}/db"
    local files_script="${directory}/files"
    local output="${directory}/output"
    local status

    make_component "$db_script" 0
    make_component "$files_script" 0

    set +e
    run_orchestrator \
        "$db_script" \
        "$files_script" \
        "${directory}/missing/lock" \
        "$output"
    status=$?
    set -e

    [[ "$status" == 4 ]] &&
        grep -Eq 'Result \.+ INTERNAL_ERROR' "$output"
}

test_concurrent_execution_and_lock_release() {
    local directory="${TEST_DIRECTORY}/concurrent"
    local db_script="${directory}/db"
    local files_script="${directory}/files"
    local output_one="${directory}/one.out"
    local output_two="${directory}/two.out"
    local output_three="${directory}/three.out"
    local ready="${directory}/ready"
    local release="${directory}/release"
    local marker="${directory}/runs"
    local first_pid
    local first_status
    local second_status
    local third_status

    mkdir -p "$directory"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -uo pipefail'
        printf 'printf "ready\\n" > %q\n' "$ready"
        printf 'while [[ ! -e %q ]]; do sleep 0.05; done\n' "$release"
        printf 'printf "db\\n" >> %q\n' "$marker"
    } > "$db_script"
    chmod +x "$db_script"
    make_component "$files_script" 0 "$marker"

    run_orchestrator \
        "$db_script" "$files_script" "${directory}/lock" "$output_one" &
    first_pid=$!

    for _ in {1..100}; do
        [[ -e "$ready" ]] && break
        sleep 0.05
    done
    [[ -e "$ready" ]] || return 1

    set +e
    run_orchestrator \
        "$db_script" "$files_script" "${directory}/lock" "$output_two"
    second_status=$?
    set -e

    [[ "$second_status" == 3 ]] || return 1
    [[ ! -e "$marker" ]] || return 1
    grep -Eq 'Result \.+ REJECTED' "$output_two" || return 1

    touch "$release"
    set +e
    wait "$first_pid"
    first_status=$?
    set -e
    [[ "$first_status" == 0 ]] || return 1
    [[ $(wc -l < "$marker") == 2 ]] || return 1

    set +e
    run_orchestrator \
        "$db_script" "$files_script" "${directory}/lock" "$output_three"
    third_status=$?
    set -e

    [[ "$third_status" == 0 ]] &&
        [[ $(wc -l < "$marker") == 4 ]]
}

test_no_residual_children() {
    local directory="${TEST_DIRECTORY}/children"
    local db_script="${directory}/db"
    local files_script="${directory}/files"
    local output="${directory}/output"
    local db_pid="${directory}/db.pid"
    local files_pid="${directory}/files.pid"

    mkdir -p "$directory"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf 'printf "%%s\\n" "$$" > %q\n' "$db_pid"
    } > "$db_script"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf 'printf "%%s\\n" "$$" > %q\n' "$files_pid"
    } > "$files_script"
    chmod +x "$db_script" "$files_script"

    run_orchestrator \
        "$db_script" "$files_script" "${directory}/lock" "$output" || return 1

    ! kill -0 "$(<"$db_pid")" 2>/dev/null &&
        ! kill -0 "$(<"$files_pid")" 2>/dev/null
}

test_log_key_value() {
    local directory="${TEST_DIRECTORY}/logger"
    local output="${directory}/output"
    local logfile="${directory}/logger.log"

    mkdir -p "$directory"

    (
        LOG_DIRECTORY="$directory"
        LOG_FILE="$logfile"
        # shellcheck source=../scripts/logger.sh
        source "${TEST_ROOT}/scripts/logger.sh"
        log_init
        log_key_value "Key with spaces" "value with spaces"
        ! log_key_value "missing value"
    ) >"$output" 2>&1 || return 1

    grep -Eq 'Key with spaces \.+ value with spaces' "$output" &&
        grep -Eq 'Key with spaces \.+ value with spaces' "$logfile"
}

make_interruptible_component() {
    local path="$1"
    local ready="$2"
    local parent_pid="$3"
    local descendant_pid="$4"
    local parent_signal="$5"
    local descendant_signal="$6"

    mkdir -p "$(dirname -- "$path")"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -uo pipefail'
        printf 'trap '\''printf "signal\\n" > %q; exit 0'\'' HUP INT TERM\n' "$parent_signal"
        printf 'printf "%%s\\n" "$$" > %q\n' "$parent_pid"
        printf '(\n'
        printf '    trap '\''printf "signal\\n" > %q; exit 0'\'' HUP INT TERM\n' "$descendant_signal"
        printf '    printf "%%s\\n" "$BASHPID" > %q\n' "$descendant_pid"
        printf '    while :; do read -r -t 1 _ </dev/null || true; done\n'
        printf ') &\n'
        printf 'descendant=$!\n'
        printf 'printf "ready\\n" > %q\n' "$ready"
        printf 'wait "$descendant"\n'
    } >"$path"
    chmod +x "$path"
}

test_signal_interrupt() {
    local signal="$1"
    local expected_status="$2"
    local directory="${TEST_DIRECTORY}/signal-${signal}"
    local db_script="${directory}/db"
    local files_script="${directory}/files"
    local output="${directory}/output"
    local ready="${directory}/ready"
    local parent_pid_file="${directory}/parent.pid"
    local descendant_pid_file="${directory}/descendant.pid"
    local parent_signal="${directory}/parent.signal"
    local descendant_signal="${directory}/descendant.signal"
    local lock_file="${directory}/lock"
    local status
    local parent_pid
    local descendant_pid

    make_interruptible_component \
        "$db_script" "$ready" "$parent_pid_file" "$descendant_pid_file" \
        "$parent_signal" "$descendant_signal"
    make_component "$files_script" 0

    status=$(
        python3 - \
            "$ORCHESTRATOR" "$db_script" "$files_script" "$lock_file" \
            "$output" "$ready" "$descendant_pid_file" "$signal" \
            "${TEST_DIRECTORY}/logs" <<'PY'
import os
from pathlib import Path
import signal
import sys
import time

(orchestrator, db_script, files_script, lock_file, output,
 ready, descendant_pid, signal_name, log_directory) = sys.argv[1:]
environment = os.environ.copy()
environment.update({
    "LOG_DIRECTORY": log_directory,
    "BACKUP_DB_SCRIPT": db_script,
    "BACKUP_FILES_SCRIPT": files_script,
    "BACKUP_LOCK_FILE": lock_file,
})
if signal_name == "INT":
    signal.signal(signal.SIGINT, signal.SIG_IGN)

process_pid = os.fork()
if process_pid == 0:
    os.setsid()
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    output_fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(output_fd, 1)
    os.dup2(output_fd, 2)
    os.close(output_fd)
    os.execve(orchestrator, [orchestrator], environment)

deadline = time.monotonic() + 10
while not (Path(ready).exists() and Path(descendant_pid).exists()):
    finished, status = os.waitpid(process_pid, os.WNOHANG)
    if finished:
        raise SystemExit("orchestrator exited before its component was ready")
    if time.monotonic() >= deadline:
        os.kill(process_pid, signal.SIGKILL)
        os.waitpid(process_pid, 0)
        raise SystemExit("component readiness marker timed out")
    time.sleep(0.01)

os.kill(process_pid, getattr(signal, f"SIG{signal_name}"))
_, wait_status = os.waitpid(process_pid, 0)
return_code = os.waitstatus_to_exitcode(wait_status)
print(return_code)
PY
    ) || return 1

    parent_pid=$(<"$parent_pid_file")
    descendant_pid=$(<"$descendant_pid_file")

    [[ "$status" == "$expected_status" ]] || return 1
    [[ -e "$parent_signal" && -e "$descendant_signal" ]] || return 1
    ! kill -0 "$parent_pid" 2>/dev/null || return 1
    ! kill -0 "$descendant_pid" 2>/dev/null || return 1
    grep -q "interrupted by signal ${signal}" "$output" || return 1
    ! grep -Eq 'Result \.+ (COMPLETE|FAILED|PARTIAL)' "$output" || return 1

    make_component "$db_script" 0
    set +e
    run_orchestrator \
        "$db_script" "$files_script" "$lock_file" "${directory}/after.out"
    status=$?
    set -e

    [[ "$status" == 0 ]]
}

test_sigint() {
    test_signal_interrupt INT 130
}

test_sigterm() {
    test_signal_interrupt TERM 143
}

test_sighup() {
    test_signal_interrupt HUP 129
}

setup

run_test "result matrix, non fail-fast execution, exit codes, spaces, cwd and duration" \
    test_result_matrix
run_test "consolidated component and partial summary" test_summary_states
run_test "missing child scripts return internal error" test_missing_components_are_internal_error
run_test "locking initialization failure returns internal error" test_lock_error_is_internal
run_test "concurrent execution is rejected and lock is released" \
    test_concurrent_execution_and_lock_release
run_test "component processes do not remain after completion" test_no_residual_children
run_test "log_key_value handles spaces and uses normal logger output" test_log_key_value
run_test "SIGTERM terminates the child tree, releases the lock and returns 143" test_sigterm
run_test "SIGHUP terminates the child tree, releases the lock and returns 129" test_sighup
run_test "SIGINT terminates the child tree, releases the lock and returns 130" test_sigint

printf '1..%d\n' "$TEST_COUNT"
