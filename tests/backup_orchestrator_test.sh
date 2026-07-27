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
            grep -q "Exit code ....... ${expected}" "$output" || return 1
            grep -Eq 'Duration \.{8} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$output" || return 1
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
        grep -q 'Database ........ ERROR' "$output" &&
        grep -q 'Filesystem ...... OK' "$output" &&
        grep -q 'Result .......... PARTIAL' "$output"
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
        grep -q 'Database ........ NOT_RUN' "$output" &&
        grep -q 'Filesystem ...... NOT_RUN' "$output" &&
        grep -q 'Result .......... INTERNAL_ERROR' "$output"
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
        grep -q 'Result .......... INTERNAL_ERROR' "$output"
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
    grep -q 'Result .......... REJECTED' "$output_two" || return 1

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

setup

run_test "result matrix, non fail-fast execution, exit codes, spaces, cwd and duration" \
    test_result_matrix
run_test "consolidated component and partial summary" test_summary_states
run_test "missing child scripts return internal error" test_missing_components_are_internal_error
run_test "locking initialization failure returns internal error" test_lock_error_is_internal
run_test "concurrent execution is rejected and lock is released" \
    test_concurrent_execution_and_lock_release
run_test "component processes do not remain after completion" test_no_residual_children

printf '1..%d\n' "$TEST_COUNT"
