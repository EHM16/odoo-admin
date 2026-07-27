#!/usr/bin/env bash

# ============================================================
# Odoo Admin
# OAA Archive Library
# ------------------------------------------------------------
# Version : 2.0
# ============================================================

set -uo pipefail

# archive_create retains legacy NAME SOURCE pairs (required by default).
# The explicit --descriptors mode accepts NAME SOURCE required|optional.

# ============================================================
# Generic Helpers
# ============================================================

_archive_check_arguments() {

    local argument

    for argument in "$@"; do
        [[ -n "$argument" ]] || return 1
    done

}

_archive_tar() {

    command -v tar >/dev/null 2>&1 || return 1
    tar "$@"

}

_archive_zstd() {

    command -v zstd >/dev/null 2>&1 || return 1
    zstd "$@"

}

_archive_json_escape() {

    local value="${1-}"
    local result=""
    local character
    local code
    local i

    local LC_ALL=C

    for (( i=0; i<${#value}; i++ )); do
        character="${value:i:1}"

        case "$character" in
            '"')    result+='\"' ;;
            \\)    result+='\\' ;;
            $'\b') result+='\b' ;;
            $'\f') result+='\f' ;;
            $'\n') result+='\n' ;;
            $'\r') result+='\r' ;;
            $'\t') result+='\t' ;;
            *)
                printf -v code '%d' "'$character"

                if (( code < 32 )); then
                    printf -v character '\\u%04x' "$code"
                fi

                result+="$character"
                ;;
        esac
    done

    printf '%s' "$result"

}

_archive_json_string() {

    printf '"%s"' "$(_archive_json_escape "${1-}")"

}

_archive_is_requirement() {

    [[ "${1:-}" == "required" || "${1:-}" == "optional" ]]

}

# ============================================================
# Resource Descriptors
# ============================================================

_archive_parse_resources() {

    local names_ref="${1:-}"
    local sources_ref="${2:-}"
    local requirements_ref="${3:-}"
    local descriptor_width="${4:-}"

    shift 4

    _archive_check_arguments \
        "$names_ref" \
        "$sources_ref" \
        "$requirements_ref" \
        "$descriptor_width" || return 1

    (( $# >= 2 )) || return 1
    [[ "$descriptor_width" == "2" || "$descriptor_width" == "3" ]] || return 1
    (( $# % descriptor_width == 0 )) || return 1

    local -n output_names="$names_ref"
    local -n output_sources="$sources_ref"
    local -n output_requirements="$requirements_ref"
    local name
    local source
    local requirement
    local existing

    while (( $# > 0 )); do
        name="$1"
        source="$2"
        requirement="required"

        if (( descriptor_width == 3 )); then
            requirement="$3"
        fi

        _archive_check_arguments "$name" "$source" "$requirement" || return 1
        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
        _archive_is_requirement "$requirement" || return 1

        for existing in "${output_names[@]}"; do
            [[ "$existing" != "$name" ]] || return 1
        done

        output_names+=("$name")
        output_sources+=("$source")
        output_requirements+=("$requirement")

        shift "$descriptor_width"
    done

}

_archive_validate_resources() {

    local names_ref="${1:-}"
    local sources_ref="${2:-}"
    local requirements_ref="${3:-}"

    _archive_check_arguments \
        "$names_ref" \
        "$sources_ref" \
        "$requirements_ref" || return 1

    local -n resource_names="$names_ref"
    local -n resource_sources="$sources_ref"
    local -n resource_requirements="$requirements_ref"
    local index

    for index in "${!resource_names[@]}"; do
        if fs_exists "${resource_sources[$index]}"; then
            continue
        fi

        if [[ "${resource_requirements[$index]}" != "optional" ]]; then
            printf \
                'archive: required resource missing: name=%q path=%q requirement=required\n' \
                "${resource_names[$index]}" \
                "${resource_sources[$index]}" >&2
            return 1
        fi
    done

}

_archive_resource_info() {

    local path="${1:-}"
    local type_ref="${2:-}"
    local size_ref="${3:-}"
    local entries_ref="${4:-}"

    _archive_check_arguments \
        "$path" \
        "$type_ref" \
        "$size_ref" \
        "$entries_ref" || return 1

    local value

    value=$(fs_type "$path") || return 1
    printf -v "$type_ref" '%s' "$value"

    value=$(fs_size "$path") || return 1
    printf -v "$size_ref" '%s' "$value"

    value=$(fs_entries "$path") || return 1
    printf -v "$entries_ref" '%s' "$value"

}

# ============================================================
# OAA Builder
# ============================================================

_builder_begin() {

    local output="${1:-}"
    local control_ref="${2:-}"
    local tar_ref="${3:-}"
    local compressed_ref="${4:-}"

    _archive_check_arguments \
        "$output" \
        "$control_ref" \
        "$tar_ref" \
        "$compressed_ref" || return 1

    local output_directory
    local output_name
    local value

    output_directory=$(dirname -- "$output") || return 1
    output_name=$(basename -- "$output") || return 1

    fs_mkdir "$output_directory" || return 1
    fs_exists "$output" && return 1

    value=$(fs_tempdir_in "$output_directory" ".${output_name}.control.XXXXXX") \
        || return 1
    printf -v "$control_ref" '%s' "$value"

    fs_mkdir "${value}/resources" || return 1

    value=$(fs_tempfile_in "$output_directory" ".${output_name}.tar.XXXXXX") \
        || return 1
    printf -v "$tar_ref" '%s' "$value"

    value=$(fs_tempfile_in "$output_directory" ".${output_name}.oaa.XXXXXX") \
        || return 1
    printf -v "$compressed_ref" '%s' "$value"

}

_builder_add_manifest() {

    local control_directory="${1:-}"
    local names_ref="${2:-}"
    local sources_ref="${3:-}"
    local requirements_ref="${4:-}"
    local tar_file="${5:-}"

    _archive_check_arguments \
        "$control_directory" \
        "$names_ref" \
        "$sources_ref" \
        "$requirements_ref" \
        "$tar_file" || return 1

    local -n manifest_names="$names_ref"
    local -n manifest_sources="$sources_ref"
    local -n manifest_requirements="$requirements_ref"
    local manifest="${control_directory}/manifest.json"
    local first=true
    local index
    local included
    local type
    local size
    local entries

    {
        printf '{\n'
        printf '  "format": "OAA",\n'
        printf '  "version": "1.0",\n'
        printf '  "framework": %s,\n' \
            "$(_archive_json_string "${PRODUCT_NAME:-Odoo Admin}")"
        printf '  "framework_version": %s,\n' \
            "$(_archive_json_string "${PRODUCT_VERSION:-unknown}")"
        printf '  "created": %s,\n' \
            "$(_archive_json_string "$(date --iso-8601=seconds)")"
        printf '  "hostname": %s,\n' \
            "$(_archive_json_string "$(hostname)")"
        printf '  "resources": [\n'

        for index in "${!manifest_names[@]}"; do
            included=false
            type="missing"
            size=0
            entries=0

            if fs_exists "${manifest_sources[$index]}"; then
                included=true
                _archive_resource_info \
                    "${manifest_sources[$index]}" \
                    type \
                    size \
                    entries || return 1
            fi

            if "$first"; then
                first=false
            else
                printf ',\n'
            fi

            printf '    {\n'
            printf '      "name": %s,\n' \
                "$(_archive_json_string "${manifest_names[$index]}")"
            printf '      "source": %s,\n' \
                "$(_archive_json_string "${manifest_sources[$index]}")"
            printf '      "archive_path": %s,\n' \
                "$(_archive_json_string "resources/${manifest_names[$index]}")"
            printf '      "type": %s,\n' \
                "$(_archive_json_string "$type")"
            printf '      "required": %s,\n' \
                "$([[ "${manifest_requirements[$index]}" == "required" ]] \
                    && printf true || printf false)"
            printf '      "included": %s,\n' "$included"
            printf '      "size": %s,\n' "$size"
            printf '      "entries": %s\n' "$entries"
            printf '    }'
        done

        printf '\n  ]\n'
        printf '}\n'
    } > "$manifest" || return 1

    _archive_tar \
        --create \
        --file="$tar_file" \
        --directory="$control_directory" \
        manifest.json \
        resources || return 1

}

_builder_add_resource() {

    local tar_file="${1:-}"
    local name="${2:-}"
    local source="${3:-}"
    local requirement="${4:-}"

    _archive_check_arguments \
        "$tar_file" \
        "$name" \
        "$source" \
        "$requirement" || return 1

    if ! fs_exists "$source"; then
        [[ "$requirement" == "optional" ]]
        return
    fi

    local source_parent
    local source_name
    local transform

    if [[ "$source" == "/" ]]; then
        source_parent="/"
        source_name="."
    else
        source="${source%/}"
        source_parent=$(dirname -- "$source") || return 1
        source_name=$(basename -- "$source") || return 1
    fi

    # Rename member paths and hard-link targets, but preserve symbolic-link
    # targets exactly as they exist at the source.
    transform="flags=rh;s|^[^/]*|resources/${name}|"

    _archive_tar \
        --append \
        --file="$tar_file" \
        --directory="$source_parent" \
        --transform="$transform" \
        "$source_name" || return 1

}

_builder_finish() {

    local tar_file="${1:-}"
    local compressed_file="${2:-}"

    _archive_check_arguments "$tar_file" "$compressed_file" || return 1

    _archive_zstd \
        --quiet \
        --stdout \
        "$tar_file" \
        > "$compressed_file" || return 1

}

_builder_cleanup() {

    local path
    local status=0

    for path in "$@"; do
        [[ -n "$path" ]] || continue
        fs_exists "$path" || continue
        fs_remove "$path" || status=1
    done

    return "$status"

}

# ============================================================
# Public OAA API
# ============================================================

archive_create() (

    local archive="${1:-}"

    _archive_check_arguments "$archive" || return 1
    shift

    local -a names=()
    local -a sources=()
    local -a requirements=()
    local descriptor_width=2

    if [[ "${1:-}" == "--descriptors" ]]; then
        descriptor_width=3
        shift
    fi

    _archive_parse_resources \
        names \
        sources \
        requirements \
        "$descriptor_width" \
        "$@" || return 1
    _archive_validate_resources names sources requirements || return 1

    local control_directory=""
    local tar_file=""
    local compressed_file=""

    trap '_builder_cleanup "$control_directory" "$tar_file" "$compressed_file"' EXIT

    _builder_begin \
        "$archive" \
        control_directory \
        tar_file \
        compressed_file || return 1

    _builder_add_manifest \
        "$control_directory" \
        names \
        sources \
        requirements \
        "$tar_file" || return 1

    local index

    for index in "${!names[@]}"; do
        _builder_add_resource \
            "$tar_file" \
            "${names[$index]}" \
            "${sources[$index]}" \
            "${requirements[$index]}" || return 1
    done

    _builder_finish "$tar_file" "$compressed_file" || return 1
    archive_verify "$compressed_file" || return 1
    fs_move_no_replace "$compressed_file" "$archive" || return 1

)

archive_check_environment() {

    command -v tar >/dev/null 2>&1 &&
        command -v zstd >/dev/null 2>&1 &&
        command -v python3 >/dev/null 2>&1

}

archive_extract() {

    local archive="${1:-}"
    local destination="${2:-}"

    _archive_check_arguments "$archive" "$destination" || return 1
    fs_exists "$archive" || return 1
    archive_verify "$archive" || return 1

    fs_mkdir "$destination" || return 1
    shift 2

    local -a arguments=(
        --extract
        --zstd
        --directory="$destination"
        --file="$archive"
        --keep-old-files
    )

    if (( $# > 0 )); then
        arguments+=(-- "$@")
    fi

    _archive_tar "${arguments[@]}"

}

archive_list() {

    local archive="${1:-}"

    _archive_check_arguments "$archive" || return 1
    fs_exists "$archive" || return 1

    archive_manifest "$archive" |
        python3 -c '
import json
import sys
for resource in json.load(sys.stdin)["resources"]:
    print(resource["name"])
'

}

archive_manifest() {

    local archive="${1:-}"

    _archive_check_arguments "$archive" || return 1
    fs_exists "$archive" || return 1

    _archive_tar \
        --extract \
        --zstd \
        --to-stdout \
        --file="$archive" \
        manifest.json

}

_archive_verify_members() {

    local archive="${1:-}"
    local member
    local manifest_count=0
    local has_resources=false

    while IFS= read -r member; do
        case "$member" in
            manifest.json)
                manifest_count=$((manifest_count + 1))
                ;;
            resources|resources/)
                has_resources=true
                ;;
            ""|/*|../*|*/../*|*/..)
                return 1
                ;;
            resources/*)
                ;;
            *)
                return 1
                ;;
        esac
    done < <(
        _archive_tar \
            --list \
            --zstd \
            --file="$archive"
    ) || return 1

    (( manifest_count == 1 )) && "$has_resources"

}

_archive_verify_manifest() {

    local archive="${1:-}"
    archive_manifest "$archive" |
        python3 -c '
import json
import re
import sys

data = json.load(sys.stdin)
if not isinstance(data, dict) or data.get("format") != "OAA" or data.get("version") != "1.0":
    raise SystemExit(1)
resources = data.get("resources")
if not isinstance(resources, list):
    raise SystemExit(1)
names = set()
paths = set()
for item in resources:
    if not isinstance(item, dict):
        raise SystemExit(1)
    required = {
        "name", "source", "archive_path", "type", "required",
        "included", "size", "entries",
    }
    if not required.issubset(item):
        raise SystemExit(1)
    name = item["name"]
    path = item["archive_path"]
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", name):
        raise SystemExit(1)
    if path != "resources/" + name or path.startswith("/") or ".." in path.split("/"):
        raise SystemExit(1)
    if name in names or path in paths:
        raise SystemExit(1)
    if not isinstance(item["required"], bool) or not isinstance(item["included"], bool):
        raise SystemExit(1)
    if not isinstance(item["size"], int) or item["size"] < 0:
        raise SystemExit(1)
    if not isinstance(item["entries"], int) or item["entries"] < 0:
        raise SystemExit(1)
    names.add(name)
    paths.add(path)
'

}

_archive_verify_resource_map() {

    local archive="${1:-}"
    local archive_path
    local included
    local member
    local found
    local -a members=()

    mapfile -t members < <(
        _archive_tar \
            --list \
            --zstd \
            --file="$archive"
    ) || return 1

    while IFS=$'\t' read -r archive_path included; do
        found=false

        for member in "${members[@]}"; do
            if [[ "$member" == "$archive_path" ||
                  "$member" == "${archive_path}/"* ]]; then
                found=true
                break
            fi
        done

        if [[ "$included" == "true" ]]; then
            "$found" || return 1
        else
            "$found" && return 1
        fi
    done < <(
        archive_manifest "$archive" |
            python3 -c '
import json
import sys
for item in json.load(sys.stdin)["resources"]:
    print(item["archive_path"], str(item["included"]).lower(), sep="\t")
'
    )

    return 0

}

archive_verify() {

    local archive="${1:-}"

    _archive_check_arguments "$archive" || return 1
    fs_exists "$archive" || return 1

    _archive_tar \
        --list \
        --zstd \
        --file="$archive" \
        >/dev/null 2>&1 || return 1

    _archive_verify_members "$archive" || return 1
    _archive_verify_manifest "$archive" || return 1
    _archive_verify_resource_map "$archive" || return 1

}
