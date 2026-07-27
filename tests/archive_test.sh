#!/usr/bin/env bash

set -uo pipefail

readonly TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEST_HELPERS="${TEST_ROOT}/tests/helpers"

if ! command -v zstd >/dev/null 2>&1; then
    ZSTD_HELPER_DIRECTORY=$(mktemp -d)
    cp "${TEST_HELPERS}/zstd" "${ZSTD_HELPER_DIRECTORY}/zstd"
    chmod +x "${ZSTD_HELPER_DIRECTORY}/zstd"
    PATH="${ZSTD_HELPER_DIRECTORY}:${PATH}"
else
    ZSTD_HELPER_DIRECTORY=""
fi

source "${TEST_ROOT}/scripts/fs.sh"
source "${TEST_ROOT}/scripts/archive.sh"

PRODUCT_NAME='Odoo "Admin"'
PRODUCT_VERSION='test\1'

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
    trap 'rm -rf -- "$TEST_DIRECTORY" "${ZSTD_HELPER_DIRECTORY:-}"' EXIT

    mkdir -p \
        "${TEST_DIRECTORY}/source one/empty directory" \
        "${TEST_DIRECTORY}/source two"

    printf 'alpha\n' > "${TEST_DIRECTORY}/single file.txt"
    printf 'beta\n' > "${TEST_DIRECTORY}/source one/file with spaces.txt"
    printf 'gamma\n' > "${TEST_DIRECTORY}/source two/other.txt"
    chmod 640 "${TEST_DIRECTORY}/source one/file with spaces.txt"
    touch -t 202401020304 "${TEST_DIRECTORY}/source one/file with spaces.txt"
    ln -s "file with spaces.txt" "${TEST_DIRECTORY}/source one/link"
    ln "${TEST_DIRECTORY}/source one/file with spaces.txt" \
        "${TEST_DIRECTORY}/source one/hardlink"
}

test_create_file() {
    local archive="${TEST_DIRECTORY}/file.oaa"

    archive_create \
        "$archive" \
        single "${TEST_DIRECTORY}/single file.txt" &&
        archive_verify "$archive"
}

test_rejects_escaping_symlink_resource() {
    local archive="${TEST_DIRECTORY}/symlink.oaa"

    ! archive_create \
        "$archive" \
        link "${TEST_DIRECTORY}/source one/link" &&
        [[ ! -e "$archive" ]]
}

test_create_directory_and_multiple_sources() {
    local archive="${TEST_DIRECTORY}/multiple.oaa"
    local listing

    archive_create \
        "$archive" \
        first "${TEST_DIRECTORY}/source one" \
        second "${TEST_DIRECTORY}/source two" || return 1

    listing=$(tar --list --zstd --file="$archive") || return 1

    grep -q '^resources/first/empty directory/$' <<< "$listing" &&
        grep -q '^resources/first/hardlink$' <<< "$listing" &&
        grep -q '^resources/first/link$' <<< "$listing" &&
        grep -q '^resources/second/other.txt$' <<< "$listing"
}

test_optional_missing() {
    local archive="${TEST_DIRECTORY}/optional.oaa"
    local manifest

    archive_create \
        "$archive" \
        --descriptors \
        present "${TEST_DIRECTORY}/single file.txt" required \
        absent "${TEST_DIRECTORY}/does not exist" optional || return 1

    manifest=$(archive_manifest "$archive") || return 1

    python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["resources"][1]["included"] is False' \
        <<< "$manifest"
}

test_required_missing() {
    ! archive_create \
        "${TEST_DIRECTORY}/required.oaa" \
        --descriptors \
        absent "${TEST_DIRECTORY}/does not exist" required &&
        [[ ! -e "${TEST_DIRECTORY}/required.oaa" ]]
}

test_existing_output() {
    local archive="${TEST_DIRECTORY}/existing.oaa"

    printf 'keep\n' > "$archive"

    ! archive_create \
        "$archive" \
        single "${TEST_DIRECTORY}/single file.txt" &&
        [[ $(< "$archive") == "keep" ]]
}

test_list_manifest_verify_extract() {
    local archive="${TEST_DIRECTORY}/roundtrip.oaa"
    local destination="${TEST_DIRECTORY}/extract"
    local mode
    local source_timestamp
    local timestamp

    archive_create \
        "$archive" \
        first "${TEST_DIRECTORY}/source one" || return 1

    [[ $(archive_list "$archive") == "first" ]] || return 1
    archive_manifest "$archive" | python3 -m json.tool >/dev/null || return 1
    archive_verify "$archive" || return 1
    archive_extract "$archive" "$destination" || return 1

    [[ -d "${destination}/resources/first/empty directory" ]] || return 1
    [[ -L "${destination}/resources/first/link" ]] || return 1
    [[ $(readlink "${destination}/resources/first/link") == "file with spaces.txt" ]] \
        || return 1

    mode=$(stat -c %a "${destination}/resources/first/file with spaces.txt")
    source_timestamp=$(stat -c %Y "${TEST_DIRECTORY}/source one/file with spaces.txt")
    timestamp=$(stat -c %Y "${destination}/resources/first/file with spaces.txt")

    [[ "$mode" == "640" && "$timestamp" == "$source_timestamp" ]]
}

test_extract_requires_absent_destination() {
    local archive="${TEST_DIRECTORY}/extract-destination.oaa"
    local destination="${TEST_DIRECTORY}/occupied"

    archive_create "$archive" one "${TEST_DIRECTORY}/single file.txt" || return 1
    mkdir "$destination"
    printf 'keep\n' > "${destination}/existing"

    ! archive_extract "$archive" "$destination" &&
        [[ $(<"${destination}/existing") == "keep" ]] &&
        [[ ! -e "${destination}/resources" ]]
}

test_corrupt_archive() {
    local archive="${TEST_DIRECTORY}/corrupt.oaa"

    printf 'not an archive\n' > "$archive"
    ! archive_verify "$archive"
}

test_tar_failure_cleanup() {
    local output="${TEST_DIRECTORY}/tar-failure.oaa"

    (
        _archive_tar() { return 1; }
        ! archive_create \
            "$output" \
            single "${TEST_DIRECTORY}/single file.txt"
    ) || return 1

    [[ ! -e "$output" ]] &&
        ! compgen -G "${TEST_DIRECTORY}/.tar-failure.oaa.*" >/dev/null
}

test_zstd_failure_cleanup() {
    local output="${TEST_DIRECTORY}/zstd-failure.oaa"

    (
        _archive_zstd() { return 1; }
        ! archive_create \
            "$output" \
            single "${TEST_DIRECTORY}/single file.txt"
    ) || return 1

    [[ ! -e "$output" ]] &&
        ! compgen -G "${TEST_DIRECTORY}/.zstd-failure.oaa.*" >/dev/null
}

test_no_staged_resource_copy() {
    local output="${TEST_DIRECTORY}/no-copy.oaa"

    (
        fs_copy() { return 99; }
        archive_create \
            "$output" \
            single "${TEST_DIRECTORY}/single file.txt"
    ) || return 1

    archive_verify "$output"
}

test_required_missing_diagnostic() {
    local error

    error=$(
        archive_create \
            "${TEST_DIRECTORY}/diagnostic.oaa" \
            --descriptors \
            critical "${TEST_DIRECTORY}/missing critical" required 2>&1
    ) && return 1

    [[ "$error" == *"name=critical"* &&
       "$error" == *"missing\\ critical"* &&
       "$error" == *"requirement=required"* ]]
}

test_json_special_characters() {
    local archive="${TEST_DIRECTORY}/json.oaa"
    local source="${TEST_DIRECTORY}/quote\" slash\\ tab"$'\t'" utf8-á"

    printf 'special\n' > "$source"
    PRODUCT_NAME=$'Odoo "Admin"\\\t\n\r\001 UTF-8 á'
    PRODUCT_VERSION=$'test\\2'

    archive_create "$archive" special "$source" || return 1
    archive_manifest "$archive" |
        python3 -c 'import json,sys; data=json.load(sys.stdin); assert "á" in data["framework"]'
}

test_rejects_source_name_with_newline() {
    local source="${TEST_DIRECTORY}/newline-source"
    local archive="${TEST_DIRECTORY}/newline.oaa"

    mkdir "$source"
    printf 'unsafe\n' > "${source}/line"$'\n'"break"

    ! archive_create "$archive" unsafe "$source" &&
        [[ ! -e "$archive" ]]
}

make_test_archive() {
    local archive="$1"
    local directory="$2"

    tar --create --directory="$directory" manifest.json resources |
        zstd --quiet --stdout > "$archive"
}

test_invalid_archives() {
    local root="${TEST_DIRECTORY}/invalid"
    local archive

    mkdir -p "$root/resources"
    printf '{"format":"OAA","version":"1.0","resources":[]}\n' > "$root/manifest.json"

    archive="${TEST_DIRECTORY}/missing-root.oaa"
    tar --create --directory="$root" manifest.json |
        zstd --quiet --stdout > "$archive"
    ! archive_verify "$archive" || return 1

    archive="${TEST_DIRECTORY}/invalid-manifest.oaa"
    printf '{invalid\n' > "$root/manifest.json"
    make_test_archive "$archive" "$root"
    ! archive_verify "$archive" || return 1

    archive="${TEST_DIRECTORY}/duplicate-manifest.oaa"
    local duplicate_tar="${TEST_DIRECTORY}/duplicate.tar"
    printf '{"format":"OAA","version":"1.0","resources":[]}\n' > "$root/manifest.json"
    tar --create --file="$duplicate_tar" --directory="$root" manifest.json resources
    tar --append --file="$duplicate_tar" --directory="$root" manifest.json
    zstd --quiet --stdout "$duplicate_tar" > "$archive"
    ! archive_verify "$archive" || return 1

    archive="${TEST_DIRECTORY}/traversal.oaa"
    printf '{"format":"OAA","version":"1.0","resources":[]}\n' > "$root/manifest.json"
    tar --create --directory="$root" manifest.json resources \
        --transform='s|^resources$|../escape|' |
        zstd --quiet --stdout > "$archive"
    ! archive_verify "$archive"
}

test_verification_and_publication_failure_cleanup() {
    local verify_output="${TEST_DIRECTORY}/verify-failure.oaa"
    local publish_output="${TEST_DIRECTORY}/publish-failure.oaa"

    (
        archive_verify() { return 1; }
        ! archive_create \
            "$verify_output" \
            one "${TEST_DIRECTORY}/single file.txt"
    ) || return 1

    (
        fs_move_no_replace() { return 1; }
        ! archive_create \
            "$publish_output" \
            one "${TEST_DIRECTORY}/single file.txt"
    ) || return 1

    [[ ! -e "$verify_output" && ! -e "$publish_output" ]] &&
        ! compgen -G "${TEST_DIRECTORY}/.verify-failure.oaa.*" >/dev/null &&
        ! compgen -G "${TEST_DIRECTORY}/.publish-failure.oaa.*" >/dev/null
}

test_declared_resource_absent() {
    local archive="${TEST_DIRECTORY}/declared-absent.oaa"
    local root="${TEST_DIRECTORY}/declared-absent"

    mkdir -p "$root/resources"
    printf '%s\n' \
        '{"format":"OAA","version":"1.0","resources":[{"name":"lost","source":"/x","archive_path":"resources/lost","type":"file","required":true,"included":true,"size":1,"entries":1}]}' \
        > "$root/manifest.json"
    make_test_archive "$archive" "$root"

    ! archive_verify "$archive"
}

test_rejects_undeclared_physical_resource() {
    local archive="${TEST_DIRECTORY}/undeclared.oaa"
    local root="${TEST_DIRECTORY}/undeclared"

    mkdir -p "$root/resources/injected"
    printf 'injected\n' > "$root/resources/injected/payload"
    printf '%s\n' \
        '{"format":"OAA","version":"1.0","resources":[]}' \
        > "$root/manifest.json"
    make_test_archive "$archive" "$root"

    ! archive_verify "$archive"
}

test_rejects_invalid_manifest_invariants() {
    local archive="${TEST_DIRECTORY}/manifest-invariants.oaa"
    local root="${TEST_DIRECTORY}/manifest-invariants"
    local item

    mkdir -p "$root/resources"

    for item in \
        '{"name":"x","source":7,"archive_path":"resources/x","type":"missing","required":false,"included":false,"size":0,"entries":0}' \
        '{"name":"x","source":"/x","archive_path":"resources/x","type":7,"required":false,"included":false,"size":0,"entries":0}' \
        '{"name":"x","source":"/x","archive_path":"resources/x","type":"file","required":false,"included":false,"size":0,"entries":0}' \
        '{"name":"x","source":"/x","archive_path":"resources/x","type":"missing","required":true,"included":false,"size":0,"entries":0}' \
        '{"name":"x","source":"/x","archive_path":"resources/x","type":"missing","required":false,"included":false,"size":1,"entries":0}' \
        '{"name":"x","source":"/x","archive_path":"resources/x","type":"unknown","required":false,"included":true,"size":0,"entries":1}' \
        '{"name":"x","source":"/x","archive_path":"resources/x","type":"missing","required":false,"included":true,"size":0,"entries":1}'
    do
        printf '{"format":"OAA","version":"1.0","resources":[%s]}\n' "$item" \
            > "$root/manifest.json"
        rm -rf -- "$root/resources"
        mkdir -p "$root/resources/x"
        make_test_archive "$archive" "$root"
        ! archive_verify "$archive" || return 1
    done
}

make_link_archive() {
    local archive="$1"
    local kind="$2"
    local target="$3"
    local tar_file="${archive}.tar"

    python3 - "$tar_file" "$kind" "$target" <<'PY'
import io
import json
import sys
import tarfile

tar_path, kind, target = sys.argv[1:]
manifest = {
    "format": "OAA",
    "version": "1.0",
    "resources": [{
        "name": "safe",
        "source": "/source",
        "archive_path": "resources/safe",
        "type": "directory",
        "required": True,
        "included": True,
        "size": 0,
        "entries": 1,
    }],
}
with tarfile.open(tar_path, "w") as archive:
    payload = json.dumps(manifest).encode()
    info = tarfile.TarInfo("manifest.json")
    info.size = len(payload)
    archive.addfile(info, io.BytesIO(payload))
    root = tarfile.TarInfo("resources")
    root.type = tarfile.DIRTYPE
    archive.addfile(root)
    resource = tarfile.TarInfo("resources/safe")
    resource.type = tarfile.DIRTYPE
    archive.addfile(resource)
    link = tarfile.TarInfo("resources/safe/link")
    link.type = tarfile.SYMTYPE if kind == "symlink" else tarfile.LNKTYPE
    link.linkname = target
    archive.addfile(link)
PY
    zstd --quiet --stdout "$tar_file" > "$archive"
}

test_rejects_unsafe_link_targets() {
    local archive="${TEST_DIRECTORY}/unsafe-link.oaa"
    local kind
    local target
    local other_resource

    for kind in symlink hardlink; do
        if [[ "$kind" == "symlink" ]]; then
            other_resource="../other/file"
        else
            other_resource="resources/other/file"
        fi
        for target in \
            "/etc/passwd" \
            "../../escape" \
            "$other_resource"
        do
            make_link_archive "$archive" "$kind" "$target" || return 1
            ! archive_verify "$archive" || return 1
        done
    done
}

test_concurrent_publication() {
    local archive="${TEST_DIRECTORY}/concurrent.oaa"
    local status_one="${TEST_DIRECTORY}/status-one"
    local status_two="${TEST_DIRECTORY}/status-two"

    (archive_create "$archive" one "${TEST_DIRECTORY}/single file.txt"; echo $? > "$status_one") &
    local pid_one=$!
    (archive_create "$archive" two "${TEST_DIRECTORY}/source two"; echo $? > "$status_two") &
    local pid_two=$!
    wait "$pid_one"
    wait "$pid_two"

    [[ $(( $(<"$status_one") + $(<"$status_two") )) -eq 1 ]] || return 1
    archive_verify "$archive" || return 1

    local winner
    winner=$(archive_list "$archive") || return 1
    local destination="${TEST_DIRECTORY}/concurrent-extract"
    archive_extract "$archive" "$destination" || return 1

    case "$winner" in
        one)
            [[ $(<"${destination}/resources/one") == "alpha" ]] &&
                [[ ! -e "${destination}/resources/two" ]]
            ;;
        two)
            [[ $(<"${destination}/resources/two/other.txt") == "gamma" ]] &&
                [[ ! -e "${destination}/resources/one" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

test_publication_rollback_states() {
    local source="${TEST_DIRECTORY}/rollback-source"
    local destination="${TEST_DIRECTORY}/rollback-destination"

    printf 'complete\n' > "$source"
    (
        local calls=0
        _fs_unlink() {
            calls=$((calls + 1))
            if (( calls == 1 )); then
                return 1
            fi
            rm -- "$1"
        }
        ! fs_move_no_replace "$source" "$destination"
    ) || return 1
    [[ -e "$source" && ! -e "$destination" ]] || return 1

    (
        _fs_unlink() { return 1; }
        fs_move_no_replace "$source" "$destination"
        [[ $? -eq 2 ]]
    ) || return 1

    [[ -e "$source" && -e "$destination" ]] &&
        [[ "$source" -ef "$destination" ]]
}

setup

run_test "backs up one file" test_create_file
run_test "rejects a symlink resource that escapes its logical root" \
    test_rejects_escaping_symlink_resource
run_test "backs up directories and resources from different paths" \
    test_create_directory_and_multiple_sources
run_test "records a missing optional resource" test_optional_missing
run_test "rejects a missing required resource" test_required_missing
run_test "diagnoses a missing required resource" test_required_missing_diagnostic
run_test "does not overwrite an existing output" test_existing_output
run_test "escapes JSON special characters and UTF-8" test_json_special_characters
run_test "lists, reads, verifies and extracts a valid OAA" \
    test_list_manifest_verify_extract
run_test "requires an absent extraction destination" \
    test_extract_requires_absent_destination
run_test "rejects a corrupt archive" test_corrupt_archive
run_test "rejects structurally invalid archives" test_invalid_archives
run_test "rejects a declared but absent resource" test_declared_resource_absent
run_test "rejects an undeclared physical resource" \
    test_rejects_undeclared_physical_resource
run_test "enforces manifest invariants and known types" \
    test_rejects_invalid_manifest_invariants
run_test "rejects unsafe symbolic and hard link targets" \
    test_rejects_unsafe_link_targets
run_test "rejects source names containing newlines" \
    test_rejects_source_name_with_newline
run_test "publishes one complete concurrent archive" test_concurrent_publication
run_test "defines publication rollback states" test_publication_rollback_states
run_test "cleans after verification and publication failures" \
    test_verification_and_publication_failure_cleanup
run_test "cleans temporary files after tar failure" test_tar_failure_cleanup
run_test "cleans temporary files after zstd failure" test_zstd_failure_cleanup
run_test "does not call fs_copy to stage resources" test_no_staged_resource_copy

printf '1..%d\n' "$TEST_COUNT"
