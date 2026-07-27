#!/usr/bin/env bash

# ============================================================
# Odoo Admin
# Archive Library
# ------------------------------------------------------------
# Version : 1.0
# ============================================================

set -uo pipefail

# ============================================================
# Funciones Privadas
# ============================================================

_archive_check_arguments() {

    local argument

    for argument in "$@"; do

        [[ -n "$argument" ]] || return 1

    done

    return 0

}

_archive_tar() {

    command -v tar >/dev/null 2>&1 || return 1

    tar "$@"

}

_archive_validate_resources() {

    local name
    local path

    (( $# >= 2 )) || return 1
    (( $# % 2 == 0 )) || return 1

    while (( $# > 0 )); do

        name="$1"
        path="$2"

        _archive_check_arguments \
            "$name" \
            "$path" || return 1

        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

        fs_exists "$path" || return 1

        shift 2

    done

    return 0

}

_archive_resource_info() {

    local path="${1:-}"

    local __type="${2:-}"
    local __size="${3:-}"
    local __entries="${4:-}"

    _archive_check_arguments \
        "$path" \
        "$__type" \
        "$__size" \
        "$__entries" || return 1

   local value

   value=$(fs_type "$path") || return 1
   printf -v "$__type" "%s" "$value"

   value=$(fs_size "$path") || return 1
   printf -v "$__size" "%s" "$value"

   value=$(fs_entries "$path") || return 1
   printf -v "$__entries" "%s" "$value"
   
   return 0

}

# ============================================================
# Crear Manifest OAA
# ============================================================

_archive_create_manifest() {

    local manifest="${1:-}"

    shift

    _archive_check_arguments "$manifest" || return 1

    local first=true

    {

        echo "{"
        echo "    \"format\": \"OAA\","
        echo "    \"version\": \"1.0\","
        echo "    \"framework\": \"${PRODUCT_NAME}\","
        echo "    \"framework_version\": \"${PRODUCT_VERSION}\","
        echo "    \"created\": \"$(date --iso-8601=seconds)\","
        echo "    \"hostname\": \"$(hostname)\","
        echo "    \"resources\": ["

        while (( $# > 0 )); do

            local name="$1"
            shift

            local path="$1"
            shift

            local type
            local size
            local entries

            _archive_resource_info \
                "$path" \
                type \
                size \
                entries || return 1

            if $first; then

                first=false

            else

                echo ","

            fi

            cat <<EOF
        {
            "name": "$name",
            "type": "$type",
            "required": true,
            "size": $size,
            "entries": $entries
        }
EOF

        done

        echo
        echo "    ]"
        echo "}"

    } > "$manifest"

}

# ============================================================
# Preparar Recursos
# ============================================================

_archive_stage_resources() {

    local workspace="${1:-}"

    shift

    _archive_check_arguments "$workspace" || return 1

    while (( $# > 0 )); do

        local name="$1"
        shift

        local path="$1"
        shift

        fs_copy \
            "$path" \
            "${workspace}/${name}" \
            || return 1

    done

    return 0

}

# ============================================================
# Construir Workspace OAA
# ============================================================

_archive_build_workspace() {

    local workspace="${1:-}"

    shift

    _archive_check_arguments "$workspace" || return 1

    #
    # Manifest
    #

    _archive_create_manifest \
        "${workspace}/manifest.json" \
        "$@" || return 1

    #
    # Recursos
    #

    _archive_stage_resources \
        "$workspace" \
        "$@" || return 1

    return 0

}

# ============================================================
# Limpiar Workspace
# ============================================================

_archive_cleanup_workspace() {

    local workspace="${1:-}"

    _archive_check_arguments "$workspace" || return 1

    fs_remove "$workspace"

}

# ============================================================
# Crear Archivo OAA
# ============================================================

archive_create() {

    local archive="${1:-}"

    _archive_check_arguments "$archive" || return 1

    shift

    #
    # Debe existir al menos un recurso
    #

    (( $# >= 2 )) || return 1

    #
    # Los recursos siempre son pares:
    #
    # nombre ruta
    #

    (( $# % 2 == 0 )) || return 1

    #
    # Verificar recursos
    #

    _archive_validate_resources "$@" || return 1

    #
    # Directorio temporal
    #

    local workspace

    workspace=$(fs_tempdir) || return 1

    trap '_archive_cleanup_workspace "$workspace"' EXIT

    #
    # Construcción del Workspace
    #

    _archive_build_workspace \
        "$workspace" \
        "$@" || return 1

#
# Empaquetado
#

    _archive_tar \
        --create \
        --zstd \
        --directory="$workspace" \
        --file="$archive" \
        . || return 1

    #
    # Limpieza
    #

    trap - EXIT

    _archive_cleanup_workspace "$workspace" || return 1

    #
    # Validación
    #

    fs_exists "$archive" || return 1

    archive_verify "$archive" || return 1

    return 0

}

# ============================================================
# Extraer Archivo OAA
# ============================================================

archive_extract() {

    local archive="${1:-}"
    local destination="${2:-}"

    _archive_check_arguments \
        "$archive" \
        "$destination" || return 1

    fs_exists "$archive" || return 1

    fs_mkdir "$destination" || return 1

    shift 2

    #
    # Restauración completa
    #

    if (( $# == 0 )); then

       _archive_tar \
           --extract \
           --zstd \
           --directory="$destination" \
           --file="$archive" \
           || return 1

    return 0

    fi

    #
    # Restauración parcial
    #

    _archive_tar \
    --extract \
    --zstd \
    --directory="$destination" \
    --file="$archive" \
    "$@" || return 1

   return 0

}

# ============================================================
# Listar Recursos
# ============================================================

archive_list() {

    local archive="${1:-}"

    _archive_check_arguments "$archive" || return 1

    fs_exists "$archive" || return 1

    local manifest

manifest=$(
    _archive_tar \
        --extract \
        --zstd \
        --to-stdout \
        --file="$archive" \
        manifest.json
) || return 1

grep '"name"' <<< "$manifest" \
    | cut -d'"' -f4 \
    || return 1

return 0

}

# ============================================================
# Obtener Manifest
# ============================================================

archive_manifest() {

    local archive="${1:-}"

    _archive_check_arguments "$archive" || return 1

    fs_exists "$archive" || return 1

    _archive_tar \
       --extract \
       --zstd \
       --to-stdout \
       --file="$archive" \
       manifest.json \
       || return 1

return 0

}

# ============================================================
# Verificar Archivo OAA
# ============================================================

archive_verify() {

    local archive="${1:-}"

    _archive_check_arguments "$archive" || return 1

    fs_exists "$archive" || return 1

  #
  # Integridad del archivo
  #

_archive_tar \
    --list \
    --file="$archive" \
    >/dev/null 2>&1 || return 1

  #
  # Manifest
  #

local manifest

manifest=$(
    _archive_tar \
        --extract \
        --zstd \
        --to-stdout \
        --file="$archive" \
        manifest.json
) || return 1

grep -q '"format"[[:space:]]*:' <<< "$manifest" || return 1
grep -q '"version"[[:space:]]*:' <<< "$manifest" || return 1
grep -q '"resources"[[:space:]]*:' <<< "$manifest" || return 1

return 0

}