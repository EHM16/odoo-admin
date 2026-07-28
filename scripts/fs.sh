#!/usr/bin/env bash

# ============================================================
# Odoo Admin
# Filesystem Library
# ------------------------------------------------------------
# Version : 1.0
# ============================================================

set -uo pipefail

# ============================================================
# Funciones Privadas
# ============================================================

_fs_check_arguments() {

    local argument

    for argument in "$@"; do

        [[ -n "$argument" ]] || return 1

    done

    return 0

}

# ============================================================
# Directorios
# ============================================================

fs_mkdir() {

    local directory="${1:-}"

    _fs_check_arguments "$directory" || return 1

    mkdir -p "$directory"

}

fs_mkdir_new() {

    local directory="${1:-}"

    _fs_check_arguments "$directory" || return 1

    mkdir -- "$directory"

}

fs_is_writable() {

    local directory="${1:-}"
    local test_file

    _fs_check_arguments "$directory" || return 1

    mkdir -p "$directory" || return 1

    test_file="${directory}/.write_test"

    touch "$test_file" 2>/dev/null || return 1

    rm -f "$test_file"

    return 0

}

# ============================================================
# Información
# ============================================================

fs_exists() {

    local path="${1:-}"

    _fs_check_arguments "$path" || return 1

    [[ -e "$path" || -L "$path" ]]

}

fs_size() {

    local path="${1:-}"

    _fs_check_arguments "$path" || return 1

    if [[ -L "$path" ]]; then

        stat -c %s "$path"

    elif [[ -d "$path" ]]; then

        du -sb "$path" | cut -f1

    else

        stat -c %s "$path"

    fi

}

fs_count() {

    local directory="${1:-}"
    local pattern="${2:-*}"

    _fs_check_arguments "$directory" || return 1

    find "$directory" \
        -maxdepth 1 \
        -type f \
        -name "$pattern" \
        | wc -l

}

fs_entries() {

    local path="${1:-}"

    _fs_check_arguments "$path" || return 1

    if [[ -L "$path" ]]; then

        echo 1

    elif [[ -d "$path" ]]; then

        find "$path" \
            -mindepth 1 \
            | wc -l

    else

        echo 1

    fi

}

fs_type() {

    local path="${1:-}"

    _fs_check_arguments "$path" || return 1

    if [[ -L "$path" ]]; then

        echo "symlink"

    elif [[ -d "$path" ]]; then

        echo "directory"

    elif [[ -f "$path" ]]; then

        echo "file"

    else

        echo "unknown"

        return 1

    fi

}

# ============================================================
# Búsqueda
# ============================================================

fs_list() {

    local directory="${1:-}"
    local pattern="${2:-*}"

    _fs_check_arguments "$directory" || return 1

    find "$directory" \
        -maxdepth 1 \
        -type f \
        -name "$pattern" \
        | sort

}

fs_latest() {

    local directory="${1:-}"
    local pattern="${2:-*}"

    _fs_check_arguments "$directory" || return 1

    fs_list "$directory" "$pattern" | tail -n 1

}

fs_oldest() {

    local directory="${1:-}"
    local pattern="${2:-*}"

    _fs_check_arguments "$directory" || return 1

    fs_list "$directory" "$pattern" | head -n 1

}

# ============================================================
# Operaciones
# ============================================================

fs_copy() {

    local source="${1:-}"
    local destination="${2:-}"

    _fs_check_arguments \
        "$source" \
        "$destination" || return 1

    cp -a \
        "$source" \
        "$destination"

}

fs_move() {

    local source="${1:-}"
    local destination="${2:-}"

    _fs_check_arguments \
        "$source" \
        "$destination" || return 1

    mv "$source" "$destination"

}

fs_remove() {

    local path="${1:-}"

    _fs_check_arguments "$path" || return 1

    rm -rf "$path"

}

fs_tempdir() {

    mktemp -d

}

fs_tempdir_in() {

    local directory="${1:-}"
    local template="${2:-}"

    _fs_check_arguments "$directory" "$template" || return 1

    mktemp \
        --directory \
        --tmpdir="$directory" \
        "$template"

}

fs_tempfile_in() {

    local directory="${1:-}"
    local template="${2:-}"

    _fs_check_arguments "$directory" "$template" || return 1

    mktemp \
        --tmpdir="$directory" \
        "$template"

}

fs_move_no_replace() {

    local source="${1:-}"
    local destination="${2:-}"

    _fs_check_arguments "$source" "$destination" || return 1
    # link(2) creates the destination atomically and fails with EEXIST when a
    # concurrent publisher wins. The caller creates source beside destination,
    # so both paths are guaranteed to be on the same filesystem.
    ln -- "$source" "$destination" || return 1
    _fs_unlink "$source" || {
        if _fs_unlink "$destination"; then
            printf \
                'fs: publication cleanup failed; destination rolled back: source=%q destination=%q\n' \
                "$source" "$destination" >&2
            return 1
        fi
        printf \
            'fs: publication cleanup and rollback failed; both names reference the same complete file: source=%q destination=%q\n' \
            "$source" "$destination" >&2
        return 2
    }

    fs_exists "$destination"

}

fs_lock_acquire() {

    local lock_file="${1:-}"
    local descriptor_variable="${2:-}"
    local descriptor
    local lock_status

    _fs_check_arguments "$lock_file" "$descriptor_variable" || return 2
    [[ "$descriptor_variable" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 2
    command -v flock >/dev/null 2>&1 || return 2

    # The returned descriptor must remain open for the complete protected
    # operation. flock releases the lock automatically when that descriptor is
    # closed or the process exits; the persistent lock file is normally kept,
    # so callers do not need an explicit unlock in their normal flow.
    exec {descriptor}>"$lock_file" || return 2

    flock --nonblock "$descriptor"
    lock_status=$?

    if (( lock_status != 0 )); then
        exec {descriptor}>&-
        (( lock_status == 1 )) && return 1
        return 2
    fi

    printf -v "$descriptor_variable" '%s' "$descriptor"

    return 0

}

_fs_unlink() {

    local path="${1:-}"

    _fs_check_arguments "$path" || return 1
    rm -- "$path"

}

# ============================================================
# Respaldos
# ============================================================

fs_backup_filename() {

    local directory="${1:-}"
    local prefix="${2:-}"
    local extension="${3:-}"
    local date_format="${4:-}"

    _fs_check_arguments \
        "$directory" \
        "$prefix" \
        "$extension" \
        "$date_format" || return 1

    printf "%s/%s_%s.%s\n" \
        "$directory" \
        "$prefix" \
        "$(date "$date_format")" \
        "$extension"

}
# ============================================================
# Retención
# ============================================================

fs_prune() {

    local directory="${1:-}"
    local pattern="${2:-}"
    local retention="${3:-}"

    _fs_check_arguments \
        "$directory" \
        "$pattern" \
        "$retention" || return 1

    local total
    local delete_count
    local i

    local -a files

    mapfile -t files < <(

        fs_list \
            "$directory" \
            "$pattern"

    )

    total=${#files[@]}

    (( total > retention )) || return 0

    delete_count=$(( total - retention ))

    for (( i=0; i<delete_count; i++ )); do

        fs_remove "${files[$i]}" || return 1

    done

    return 0

}
