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
    local identity_file="${directory}/identity"
    local files_marker="${directory}/files.ran"
    local outsider_pid_file="${directory}/outsider.pid"
    local lock_file="${directory}/lock"
    local status
    local parent_pid
    local descendant_pid
    local -a component_identity

    make_interruptible_component \
        "$db_script" "$ready" "$parent_pid_file" "$descendant_pid_file" \
        "$parent_signal" "$descendant_signal"
    make_component "$files_script" 0 "$files_marker"

    status=$(
        python3 - \
            "$ORCHESTRATOR" "$db_script" "$files_script" "$lock_file" \
            "$output" "$ready" "$descendant_pid_file" "$signal" \
            "${TEST_DIRECTORY}/logs" "$outsider_pid_file" "$parent_pid_file" \
            "$identity_file" <<'PY'
import os
from pathlib import Path
import signal
import sys
import time

(orchestrator, db_script, files_script, lock_file, output,
 ready, descendant_pid, signal_name, log_directory, outsider_pid_file,
 parent_pid_file, identity_file) = sys.argv[1:]
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

outsider_pid = os.fork()
if outsider_pid == 0:
    os.setsid()
    Path(outsider_pid_file).write_text(str(os.getpid()))
    signal.pause()

deadline = time.monotonic() + 10
while not (Path(ready).exists() and Path(descendant_pid).exists()
           and Path(outsider_pid_file).exists() and Path(parent_pid_file).exists()):
    finished, status = os.waitpid(process_pid, os.WNOHANG)
    if finished:
        raise SystemExit("orchestrator exited before its component was ready")
    if time.monotonic() >= deadline:
        os.kill(process_pid, signal.SIGKILL)
        os.waitpid(process_pid, 0)
        raise SystemExit("component readiness marker timed out")
    time.sleep(0.01)

component_pid = int(Path(parent_pid_file).read_text())
component_pgid = os.getpgid(component_pid)
component_sid = os.getsid(component_pid)
if component_pgid == os.getpgid(process_pid):
    raise SystemExit("component group unexpectedly includes orchestrator")
Path(identity_file).write_text(
    f"{component_pid}\n{component_pgid}\n{component_sid}\n"
)
os.kill(process_pid, getattr(signal, f"SIG{signal_name}"))
_, wait_status = os.waitpid(process_pid, 0)
return_code = os.waitstatus_to_exitcode(wait_status)
os.kill(outsider_pid, 0)
os.kill(outsider_pid, signal.SIGTERM)
os.waitpid(outsider_pid, 0)
print(return_code)
PY
    ) || return 1

    parent_pid=$(<"$parent_pid_file")
    descendant_pid=$(<"$descendant_pid_file")
    if [[ -n "${SIGNAL_STATUS_FILE:-}" ]]; then
        printf '%s\n' "$status" > "$SIGNAL_STATUS_FILE"
    fi

    [[ "$status" == "$expected_status" ]] || return 1
    mapfile -t component_identity < "$identity_file"
    [[ "${component_identity[0]}" == "$parent_pid" ]] || return 1
    [[ "${component_identity[0]}" == "${component_identity[1]}" ]] || return 1
    [[ "${component_identity[0]}" == "${component_identity[2]}" ]] || return 1
    [[ -e "$parent_signal" && -e "$descendant_signal" ]] || return 1
    ! kill -0 "$parent_pid" 2>/dev/null || return 1
    ! kill -0 "$descendant_pid" 2>/dev/null || return 1
    grep -q "interrupted by signal ${signal}" "$output" || return 1
    ! grep -Eq 'Result \.+ (COMPLETE|FAILED|PARTIAL)' "$output" || return 1
    [[ ! -e "$files_marker" ]] || return 1

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

make_window_runner() {
    local path="$1"
    local mode="$2"
    local ready="$3"

    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -uo pipefail'
        printf 'source %q\n' "$ORCHESTRATOR"
        if [[ "$mode" == "between" ]]; then
            printf '%s\n' 'declare CHECK_COUNT=0'
            printf '%s\n' '_backup_exit_if_signalled() {'
            printf '%s\n' '    local signal_exit_code'
            printf '%s\n' '    CHECK_COUNT=$((CHECK_COUNT + 1))'
            printf '    if (( CHECK_COUNT == 5 )); then printf "ready\\n" > %q; while [[ -z "$RECEIVED_SIGNAL" ]]; do read -r -t 0.05 _ </dev/null || true; done; fi\n' "$ready"
            printf '%s\n' '    [[ -n "$RECEIVED_SIGNAL" ]] || return 0'
            printf '%s\n' '    signal_exit_code=$(_backup_signal_exit_code "$RECEIVED_SIGNAL") || exit "$BACKUP_EXIT_INTERNAL"'
            printf '%s\n' '    exit "$signal_exit_code"'
            printf '%s\n' '}'
        else
            printf '%s\n' '_backup_log_summary() {'
            printf '    printf "ready\\n" > %q\n' "$ready"
            printf '%s\n' '    while [[ -z "$RECEIVED_SIGNAL" ]]; do read -r -t 0.05 _ </dev/null || true; done'
            printf '%s\n' '    _backup_exit_if_signalled'
            printf '%s\n' '}'
        fi
        printf '%s\n' 'main "$@"'
    } > "$path"
    chmod +x "$path"
}

run_signalled_process() {
    local program="$1"
    local signal="$2"
    local ready="$3"
    local output="$4"
    shift 4

    python3 - "$program" "$signal" "$ready" "$output" "$@" <<'PY'
import os
from pathlib import Path
import signal
import sys
import time

program, signal_name, ready, output, *environment_items = sys.argv[1:]
environment = os.environ.copy()
environment.update(item.split("=", 1) for item in environment_items)
pid = os.fork()
if pid == 0:
    os.setsid()
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    os.close(fd)
    os.execve(program, [program], environment)

deadline = time.monotonic() + 10
while not Path(ready).exists():
    finished, status = os.waitpid(pid, os.WNOHANG)
    if finished:
        raise SystemExit("process exited before the requested window")
    if time.monotonic() >= deadline:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        raise SystemExit("window readiness marker timed out")
    time.sleep(0.01)

os.kill(pid, getattr(signal, f"SIG{signal_name}"))
_, status = os.waitpid(pid, 0)
print(os.waitstatus_to_exitcode(status))
PY
}

test_signal_window() {
    local mode="$1"
    local directory="${TEST_DIRECTORY}/window-${mode}"
    local db_script="${directory}/db"
    local files_script="${directory}/files"
    local runner="${directory}/runner"
    local db_marker="${directory}/db.ran"
    local files_marker="${directory}/files.ran"
    local ready="${directory}/ready"
    local output="${directory}/output"
    local lock_file="${directory}/lock"
    local status

    mkdir -p "$directory"
    make_component "$db_script" 0 "$db_marker"
    make_component "$files_script" 0 "$files_marker"
    make_window_runner "$runner" "$mode" "$ready"

    status=$(run_signalled_process \
        "$runner" TERM "$ready" "$output" \
        "LOG_DIRECTORY=${TEST_DIRECTORY}/logs" \
        "BACKUP_DB_SCRIPT=${db_script}" \
        "BACKUP_FILES_SCRIPT=${files_script}" \
        "BACKUP_LOCK_FILE=${lock_file}") || return 1

    [[ "$status" == 143 ]] || return 1
    [[ -e "$db_marker" ]] || return 1
    if [[ "$mode" == "between" ]]; then
        [[ ! -e "$files_marker" ]] || return 1
    else
        [[ -e "$files_marker" ]] || return 1
    fi
    grep -q 'interrupted by signal TERM' "$output" || return 1
    ! grep -Eq 'Result \.+ (COMPLETE|FAILED|PARTIAL)' "$output" || return 1

    make_component "$db_script" 0
    run_orchestrator \
        "$db_script" "$files_script" "$lock_file" "${directory}/after.out"
}

test_signal_between_components() {
    test_signal_window between
}

test_signal_before_summary() {
    test_signal_window summary
}

test_signal_without_active_child() {
    local directory="${TEST_DIRECTORY}/no-active-child"
    local runner="${directory}/runner"
    local output="${directory}/output"
    local continued="${directory}/continued"
    local status

    mkdir -p "$directory"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -uo pipefail'
        printf 'source %q\n' "$ORCHESTRATOR"
        printf '%s\n' '_backup_bootstrap'
        printf '%s\n' '_backup_install_signal_handlers'
        printf '%s\n' '_backup_handle_signal HUP'
        printf 'touch %q\n' "$continued"
    } > "$runner"
    chmod +x "$runner"

    set +e
    LOG_DIRECTORY="${TEST_DIRECTORY}/logs" "$runner" >"$output" 2>&1
    status=$?
    set -e

    [[ "$status" == 129 ]] &&
        [[ ! -e "$continued" ]] &&
        grep -q 'interrupted by signal HUP' "$output" &&
        ! grep -Eq 'Result \.+ (COMPLETE|FAILED|PARTIAL)' "$output"
}

test_repeated_signals() {
    local directory="${TEST_DIRECTORY}/repeated"
    local db_script="${directory}/db"
    local files_script="${directory}/files"
    local output="${directory}/output"
    local ready="${directory}/ready"
    local parent_pid_file="${directory}/parent.pid"
    local descendant_pid_file="${directory}/descendant.pid"
    local parent_signal="${directory}/parent.signal"
    local descendant_signal="${directory}/descendant.signal"
    local status

    make_interruptible_component \
        "$db_script" "$ready" "$parent_pid_file" "$descendant_pid_file" \
        "$parent_signal" "$descendant_signal"
    make_component "$files_script" 0

    status=$(
        python3 - "$ORCHESTRATOR" "$db_script" "$files_script" "$output" \
            "$ready" "${TEST_DIRECTORY}/logs" "${directory}/lock" <<'PY'
import os
from pathlib import Path
import signal
import sys
import time

orchestrator, db_script, files_script, output, ready, logs, lock = sys.argv[1:]
environment = os.environ.copy()
environment.update(LOG_DIRECTORY=logs, BACKUP_DB_SCRIPT=db_script,
                   BACKUP_FILES_SCRIPT=files_script, BACKUP_LOCK_FILE=lock)
pid = os.fork()
if pid == 0:
    os.setsid()
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(fd, 1); os.dup2(fd, 2); os.close(fd)
    os.execve(orchestrator, [orchestrator], environment)
deadline = time.monotonic() + 10
while not Path(ready).exists():
    if time.monotonic() >= deadline:
        os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
        raise SystemExit("readiness marker timed out")
    time.sleep(0.01)
os.kill(pid, signal.SIGTERM)
try:
    os.kill(pid, signal.SIGHUP)
except ProcessLookupError:
    pass
_, wait_status = os.waitpid(pid, 0)
print(os.waitstatus_to_exitcode(wait_status))
PY
    ) || return 1

    [[ "$status" == 143 ]] &&
        [[ $(grep -c 'Backup job interrupted by signal' "$output") == 1 ]] &&
        ! kill -0 "$(<"$parent_pid_file")" 2>/dev/null &&
        ! kill -0 "$(<"$descendant_pid_file")" 2>/dev/null
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
run_test "a signal between components prevents the next component" \
    test_signal_between_components
run_test "a signal before the summary prevents a normal result" \
    test_signal_before_summary
run_test "a signal without an active child exits immediately" \
    test_signal_without_active_child
run_test "repeated signals preserve the first cancellation result" \
    test_repeated_signals

printf '1..%d\n' "$TEST_COUNT"
