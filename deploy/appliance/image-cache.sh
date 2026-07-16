#!/bin/sh

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -eu

MODE="${1:-ensure}"

BUNDLE_PATH="${OPENSHELL_IMAGE_BUNDLE:-/opt/openshell/image-bundle}"
REQUIRED_IMAGES_OVERRIDE="${OPENSHELL_IMAGE_CACHE_REQUIRED_IMAGES:-}"
COMPLETE_FILE="${OPENSHELL_IMAGE_CACHE_COMPLETE_FILE:-/var/run/openshell/image-cache-complete}"
STATE_FILE="${OPENSHELL_IMAGE_CACHE_STATE_FILE:-/var/run/openshell/image-cache.env}"
LOCK_DIR="${OPENSHELL_IMAGE_CACHE_LOCK_DIR:-/var/run/openshell/image-cache.lock}"
K3S_DATA_DIR="${OPENSHELL_K3S_DATA_DIR:-/var/lib/rancher/k3s}"
DISK_MIN_FREE_PERCENT="${OPENSHELL_IMAGE_CACHE_DISK_MIN_FREE_PERCENT:-10}"
CHECK_DISK="${OPENSHELL_IMAGE_CACHE_CHECK_DISK:-1}"
RECONCILE_INTERVAL_S="${OPENSHELL_IMAGE_CACHE_RECONCILE_INTERVAL_S:-300}"
RECONCILE_JITTER_S="${OPENSHELL_IMAGE_CACHE_RECONCILE_JITTER_S:-15}"
VERIFY_ATTEMPTS="${OPENSHELL_IMAGE_CACHE_VERIFY_ATTEMPTS:-30}"
VERIFY_DELAY_S="${OPENSHELL_IMAGE_CACHE_VERIFY_DELAY_S:-2}"
K3S_BIN="${K3S_BIN:-k3s}"

WORK_DIR=""
PREPARED_BUNDLE_DIR=""
MANIFEST_BASE_DIR=""
IMPORTED_COUNT=0
IMPORTED_ALL=0
LOCK_HELD=0

GATEWAY_IMAGE=""
SANDBOX_IMAGE=""
SUPERVISOR_IMAGE=""
AGENT_SANDBOX_CONTROLLER_IMAGE=""
GATEWAY_ARCHIVE=""
SANDBOX_ARCHIVE=""
SUPERVISOR_ARCHIVE=""
AGENT_SANDBOX_CONTROLLER_ARCHIVE=""
REQUIRED_IMAGES=""

log() {
    printf '%s\n' "openshell-image-cache: $*" >&2
}

die() {
    log "$*"
    exit 1
}

cleanup() {
    if [ "$LOCK_HELD" = "1" ]; then
        rm -f "$LOCK_DIR/pid" >/dev/null 2>&1 || true
        rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
        LOCK_HELD=0
    fi
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}

trap cleanup EXIT INT TERM

is_nonnegative_integer() {
    value="$1"
    case "$value" in
        ''|*[!0-9]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

verify_positive_integer() {
    value="$1"
    name="$2"

    if ! is_nonnegative_integer "$value" || [ "$value" -eq 0 ]; then
        die "$name must be a positive integer"
    fi
}

shell_quote() {
    value="$1"
    printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
}

ctr_cmd() {
    if command -v ctr >/dev/null 2>&1; then
        ctr -n k8s.io "$@"
        return $?
    fi

    if command -v "$K3S_BIN" >/dev/null 2>&1; then
        "$K3S_BIN" ctr -n k8s.io "$@"
        return $?
    fi

    log "neither ctr nor $K3S_BIN is available for k3s image-cache access"
    return 127
}

image_present() {
    image="$1"
    ctr_cmd images ls -q "name==$image" 2>/dev/null | grep -Fx "$image" >/dev/null 2>&1
}

check_disk_free() {
    [ "$CHECK_DISK" = "1" ] || return 0
    [ -n "$DISK_MIN_FREE_PERCENT" ] || return 0
    [ "$DISK_MIN_FREE_PERCENT" = "0" ] && return 0

    if ! is_nonnegative_integer "$DISK_MIN_FREE_PERCENT"; then
        die "OPENSHELL_IMAGE_CACHE_DISK_MIN_FREE_PERCENT must be a non-negative integer"
    fi

    disk_path="$K3S_DATA_DIR"
    [ -e "$disk_path" ] || disk_path="/"

    used_percent="$(
        df -P "$disk_path" 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }'
    )"
    [ -n "$used_percent" ] || die "could not determine free disk percent for $disk_path"

    free_percent=$((100 - used_percent))
    if [ "$free_percent" -lt "$DISK_MIN_FREE_PERCENT" ]; then
        die "free disk percent for $disk_path is ${free_percent}%, below required ${DISK_MIN_FREE_PERCENT}%"
    fi
}

acquire_lock() {
    wait_attempts="${OPENSHELL_IMAGE_CACHE_LOCK_WAIT_ATTEMPTS:-30}"
    wait_delay_s="${OPENSHELL_IMAGE_CACHE_LOCK_WAIT_DELAY_S:-1}"

    verify_positive_integer "$wait_attempts" OPENSHELL_IMAGE_CACHE_LOCK_WAIT_ATTEMPTS
    verify_positive_integer "$wait_delay_s" OPENSHELL_IMAGE_CACHE_LOCK_WAIT_DELAY_S

    mkdir -p "$(dirname "$LOCK_DIR")"
    attempt=1
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        if [ "$attempt" -ge "$wait_attempts" ]; then
            die "timed out waiting for image-cache lock: $LOCK_DIR"
        fi
        sleep "$wait_delay_s"
        attempt=$((attempt + 1))
    done

    LOCK_HELD=1
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
}

bundle_files_in_dir() {
    bundle_dir="$1"

    for bundle in \
        "$bundle_dir"/openshell-images-*.tar.zst \
        "$bundle_dir"/openshell-images-*.tar.gz \
        "$bundle_dir"/openshell-images-*.tgz \
        "$bundle_dir"/openshell-images-*.tar \
        "$bundle_dir"/potatostew-openshell-images-*.tar.zst \
        "$bundle_dir"/potatostew-openshell-images-*.tar.gz \
        "$bundle_dir"/potatostew-openshell-images-*.tgz \
        "$bundle_dir"/potatostew-openshell-images-*.tar
    do
        [ -f "$bundle" ] || continue
        printf '%s\n' "$bundle"
    done | sort
}

unpack_bundle_file() {
    bundle="$1"

    WORK_DIR="$(mktemp -d)"
    case "$bundle" in
        *.tar.zst)
            command -v zstd >/dev/null 2>&1 || die "zstd is required to unpack $bundle"
            zstd -dc "$bundle" | tar -xf - -C "$WORK_DIR"
            ;;
        *.tgz|*.tar.gz)
            tar -xzf "$bundle" -C "$WORK_DIR"
            ;;
        *.tar)
            tar -xf "$bundle" -C "$WORK_DIR"
            ;;
        *)
            die "unsupported OpenShell image bundle extension: $bundle"
            ;;
    esac

    PREPARED_BUNDLE_DIR="$WORK_DIR"
}

find_manifest_file() {
    dir="$1"
    find "$dir" -type f \( -name manifest.env -o -name manifest.json \) 2>/dev/null \
        | sort \
        | sed -n '1p'
}

prepare_bundle_dir() {
    [ -n "$PREPARED_BUNDLE_DIR" ] && return 0

    if [ -f "$BUNDLE_PATH" ]; then
        unpack_bundle_file "$BUNDLE_PATH"
        return 0
    fi

    if [ ! -d "$BUNDLE_PATH" ]; then
        die "OpenShell image bundle path does not exist: $BUNDLE_PATH"
    fi

    if [ -n "$(find_manifest_file "$BUNDLE_PATH")" ]; then
        PREPARED_BUNDLE_DIR="$BUNDLE_PATH"
        return 0
    fi

    bundle_list="$(bundle_files_in_dir "$BUNDLE_PATH")"
    if [ -z "$bundle_list" ]; then
        die "no OpenShell image bundle found in $BUNDLE_PATH"
    fi

    bundle_count="$(printf '%s\n' "$bundle_list" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [ "$bundle_count" -ne 1 ]; then
        log "multiple OpenShell image bundles found in $BUNDLE_PATH"
        printf '%s\n' "$bundle_list" >&2
        die "set OPENSHELL_IMAGE_BUNDLE to the exact bundle file"
    fi

    unpack_bundle_file "$(printf '%s\n' "$bundle_list" | sed -n '1p')"
}

json_image_field() {
    key="$1"
    field="$2"
    manifest_file="$3"

    awk -v key="$key" -v field="$field" '
        index($0, "\"" key "\"") { in_image = 1 }
        in_image && index($0, "\"" field "\"") {
            sub("^.*\"" field "\"[[:space:]]*:[[:space:]]*\"", "")
            sub("\".*$", "")
            print
            exit
        }
    ' "$manifest_file"
}

archive_path() {
    archive="$1"
    case "$archive" in
        "")
            return 0
            ;;
        /*)
            printf '%s\n' "$archive"
            ;;
        *)
            printf '%s/%s\n' "$MANIFEST_BASE_DIR" "$archive"
            ;;
    esac
}

load_manifest() {
    prepare_bundle_dir
    manifest_file="$(find_manifest_file "$PREPARED_BUNDLE_DIR")"

    if [ -z "$manifest_file" ]; then
        if [ -n "$REQUIRED_IMAGES_OVERRIDE" ]; then
            REQUIRED_IMAGES="$REQUIRED_IMAGES_OVERRIDE"
            MANIFEST_BASE_DIR="$PREPARED_BUNDLE_DIR"
            return 0
        fi
        die "OpenShell image bundle is missing manifest.env or manifest.json: $BUNDLE_PATH"
    fi

    MANIFEST_BASE_DIR="$(dirname "$manifest_file")"
    case "$manifest_file" in
        *.env)
            # shellcheck disable=SC1090
            . "$manifest_file"
            GATEWAY_IMAGE="${OPENSHELL_GATEWAY_IMAGE:-${OPENSHELL_BUNDLE_GATEWAY_IMAGE:-}}"
            SANDBOX_IMAGE="${OPENSHELL_SANDBOX_IMAGE:-${OPENSHELL_BUNDLE_SANDBOX_IMAGE:-}}"
            SUPERVISOR_IMAGE="${OPENSHELL_SUPERVISOR_IMAGE:-${OPENSHELL_BUNDLE_SUPERVISOR_IMAGE:-}}"
            AGENT_SANDBOX_CONTROLLER_IMAGE="${OPENSHELL_AGENT_SANDBOX_CONTROLLER_IMAGE:-${OPENSHELL_BUNDLE_AGENT_SANDBOX_CONTROLLER_IMAGE:-}}"
            GATEWAY_ARCHIVE="$(archive_path "${OPENSHELL_BUNDLE_GATEWAY_ARCHIVE:-images/gateway.oci.tar}")"
            SANDBOX_ARCHIVE="$(archive_path "${OPENSHELL_BUNDLE_SANDBOX_ARCHIVE:-images/sandbox.oci.tar}")"
            SUPERVISOR_ARCHIVE="$(archive_path "${OPENSHELL_BUNDLE_SUPERVISOR_ARCHIVE:-images/supervisor.oci.tar}")"
            AGENT_SANDBOX_CONTROLLER_ARCHIVE="$(archive_path "${OPENSHELL_BUNDLE_AGENT_SANDBOX_CONTROLLER_ARCHIVE:-images/agent-sandbox-controller.oci.tar}")"
            ;;
        *.json)
            GATEWAY_IMAGE="${OPENSHELL_GATEWAY_IMAGE:-$(json_image_field gateway ref "$manifest_file")}"
            SANDBOX_IMAGE="${OPENSHELL_SANDBOX_IMAGE:-$(json_image_field sandbox ref "$manifest_file")}"
            SUPERVISOR_IMAGE="${OPENSHELL_SUPERVISOR_IMAGE:-$(json_image_field supervisor ref "$manifest_file")}"
            AGENT_SANDBOX_CONTROLLER_IMAGE="${OPENSHELL_AGENT_SANDBOX_CONTROLLER_IMAGE:-$(json_image_field agent_sandbox_controller ref "$manifest_file")}"
            GATEWAY_ARCHIVE="$(archive_path "$(json_image_field gateway archive "$manifest_file")")"
            SANDBOX_ARCHIVE="$(archive_path "$(json_image_field sandbox archive "$manifest_file")")"
            SUPERVISOR_ARCHIVE="$(archive_path "$(json_image_field supervisor archive "$manifest_file")")"
            AGENT_SANDBOX_CONTROLLER_ARCHIVE="$(archive_path "$(json_image_field agent_sandbox_controller archive "$manifest_file")")"
            ;;
        *)
            die "unsupported OpenShell image bundle manifest: $manifest_file"
            ;;
    esac

    REQUIRED_IMAGES="${REQUIRED_IMAGES_OVERRIDE:-$GATEWAY_IMAGE $SANDBOX_IMAGE $SUPERVISOR_IMAGE $AGENT_SANDBOX_CONTROLLER_IMAGE}"
}

write_state_file() {
    mkdir -p "$(dirname "$STATE_FILE")"
    {
        printf 'GATEWAY_IMAGE=%s\n' "$(shell_quote "$GATEWAY_IMAGE")"
        printf 'SANDBOX_IMAGE=%s\n' "$(shell_quote "$SANDBOX_IMAGE")"
        printf 'SUPERVISOR_IMAGE=%s\n' "$(shell_quote "$SUPERVISOR_IMAGE")"
        printf 'AGENT_SANDBOX_CONTROLLER_IMAGE=%s\n' "$(shell_quote "$AGENT_SANDBOX_CONTROLLER_IMAGE")"
        printf 'OPENSHELL_IMAGE_CACHE_REQUIRED_IMAGES_EFFECTIVE=%s\n' "$(shell_quote "$REQUIRED_IMAGES")"
    } >"$STATE_FILE"
}

load_required_images_for_check() {
    if [ -n "$REQUIRED_IMAGES_OVERRIDE" ]; then
        REQUIRED_IMAGES="$REQUIRED_IMAGES_OVERRIDE"
        return 0
    fi

    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        REQUIRED_IMAGES="${OPENSHELL_IMAGE_CACHE_REQUIRED_IMAGES_EFFECTIVE:-}"
        [ -n "$REQUIRED_IMAGES" ] || die "image-cache state file did not define required images: $STATE_FILE"
        return 0
    fi

    load_manifest
}

archive_for_image() {
    image="$1"

    if [ -n "$GATEWAY_IMAGE" ] && [ "$image" = "$GATEWAY_IMAGE" ]; then
        printf '%s\n' "$GATEWAY_ARCHIVE"
    elif [ -n "$SANDBOX_IMAGE" ] && [ "$image" = "$SANDBOX_IMAGE" ]; then
        printf '%s\n' "$SANDBOX_ARCHIVE"
    elif [ -n "$SUPERVISOR_IMAGE" ] && [ "$image" = "$SUPERVISOR_IMAGE" ]; then
        printf '%s\n' "$SUPERVISOR_ARCHIVE"
    elif [ -n "$AGENT_SANDBOX_CONTROLLER_IMAGE" ] && [ "$image" = "$AGENT_SANDBOX_CONTROLLER_IMAGE" ]; then
        printf '%s\n' "$AGENT_SANDBOX_CONTROLLER_ARCHIVE"
    fi
}

import_archive() {
    archive="$1"
    [ -f "$archive" ] || die "image archive not found: $archive"
    log "importing image archive $archive"
    ctr_cmd images import "$archive" >/dev/null
    IMPORTED_COUNT=$((IMPORTED_COUNT + 1))
}

import_all_archives() {
    [ "$IMPORTED_ALL" = "1" ] && return 0
    IMPORTED_ALL=1

    for archive in \
        "$MANIFEST_BASE_DIR"/*.tar \
        "$MANIFEST_BASE_DIR"/*.oci \
        "$MANIFEST_BASE_DIR"/images/*.tar \
        "$MANIFEST_BASE_DIR"/images/*.oci \
        "$MANIFEST_BASE_DIR"/*/images/*.tar \
        "$MANIFEST_BASE_DIR"/*/images/*.oci
    do
        [ -f "$archive" ] || continue
        import_archive "$archive"
    done
}

ensure_image() {
    image="$1"
    [ -n "$image" ] || return 0

    if image_present "$image"; then
        return 0
    fi

    archive="$(archive_for_image "$image")"
    if [ -n "$archive" ] && [ -f "$archive" ]; then
        import_archive "$archive"
    else
        log "no direct archive mapping found for $image; importing all available bundle archives"
        import_all_archives
    fi
}

verify_required_image() {
    image="$1"
    attempt=1

    while [ "$attempt" -le "$VERIFY_ATTEMPTS" ]; do
        if image_present "$image"; then
            return 0
        fi

        if [ "$attempt" -lt "$VERIFY_ATTEMPTS" ]; then
            log "required image is not visible yet: $image (attempt $attempt/$VERIFY_ATTEMPTS)"
            sleep "$VERIFY_DELAY_S"
        fi

        attempt=$((attempt + 1))
    done

    log "required image is missing from k3s image cache: $image"
    return 1
}

mode_manifest_env() {
    load_manifest
    [ -n "$GATEWAY_IMAGE" ] || die "bundle manifest did not define gateway image"
    [ -n "$SANDBOX_IMAGE" ] || die "bundle manifest did not define sandbox image"
    [ -n "$SUPERVISOR_IMAGE" ] || die "bundle manifest did not define supervisor image"
    [ -n "$AGENT_SANDBOX_CONTROLLER_IMAGE" ] || die "bundle manifest did not define agent-sandbox controller image"

    printf 'GATEWAY_IMAGE=%s\n' "$(shell_quote "$GATEWAY_IMAGE")"
    printf 'SANDBOX_IMAGE=%s\n' "$(shell_quote "$SANDBOX_IMAGE")"
    printf 'SUPERVISOR_IMAGE=%s\n' "$(shell_quote "$SUPERVISOR_IMAGE")"
    printf 'AGENT_SANDBOX_CONTROLLER_IMAGE=%s\n' "$(shell_quote "$AGENT_SANDBOX_CONTROLLER_IMAGE")"
    printf 'OPENSHELL_IMAGE_CACHE_REQUIRED_IMAGES_EFFECTIVE=%s\n' "$(shell_quote "$REQUIRED_IMAGES")"
}

mode_check() {
    verify_positive_integer "$VERIFY_ATTEMPTS" OPENSHELL_IMAGE_CACHE_VERIFY_ATTEMPTS
    verify_positive_integer "$VERIFY_DELAY_S" OPENSHELL_IMAGE_CACHE_VERIFY_DELAY_S
    load_required_images_for_check
    check_disk_free

    missing=0
    for image in $REQUIRED_IMAGES; do
        [ -n "$image" ] || continue
        if ! image_present "$image"; then
            log "required image is missing from k3s image cache: $image"
            missing=1
        fi
    done

    [ "$missing" = "0" ]
}

mode_ensure() {
    verify_positive_integer "$VERIFY_ATTEMPTS" OPENSHELL_IMAGE_CACHE_VERIFY_ATTEMPTS
    verify_positive_integer "$VERIFY_DELAY_S" OPENSHELL_IMAGE_CACHE_VERIFY_DELAY_S
    acquire_lock
    load_manifest
    write_state_file
    check_disk_free

    mkdir -p "$(dirname "$COMPLETE_FILE")"
    rm -f "$COMPLETE_FILE"

    for image in $REQUIRED_IMAGES; do
        ensure_image "$image"
    done

    for image in $REQUIRED_IMAGES; do
        verify_required_image "$image"
    done

    touch "$COMPLETE_FILE"
    log "image-cache ensure complete; imported $IMPORTED_COUNT archive(s)"
}

mode_reconcile() {
    verify_positive_integer "$RECONCILE_INTERVAL_S" OPENSHELL_IMAGE_CACHE_RECONCILE_INTERVAL_S
    if ! is_nonnegative_integer "$RECONCILE_JITTER_S"; then
        die "OPENSHELL_IMAGE_CACHE_RECONCILE_JITTER_S must be a non-negative integer"
    fi

    if [ "$RECONCILE_JITTER_S" -gt 0 ]; then
        sleep $(( $$ % (RECONCILE_JITTER_S + 1) ))
    fi

    while :; do
        if ! "$0" ensure; then
            log "image-cache reconcile iteration failed"
        fi
        sleep "$RECONCILE_INTERVAL_S"
    done
}

usage() {
    cat >&2 <<'EOF'
Usage: image-cache.sh MODE

Modes:
  manifest-env  Print shell assignments for bundle image refs
  check         Verify required images exist; do not mutate image cache
  ensure        Import missing required images from the configured bundle
  reconcile     Run ensure periodically

Important environment:
  OPENSHELL_IMAGE_BUNDLE
  OPENSHELL_IMAGE_CACHE_REQUIRED_IMAGES
  OPENSHELL_IMAGE_CACHE_COMPLETE_FILE
  OPENSHELL_IMAGE_CACHE_RECONCILE_INTERVAL_S
  OPENSHELL_IMAGE_CACHE_DISK_MIN_FREE_PERCENT
EOF
}

case "$MODE" in
    manifest-env)
        mode_manifest_env
        ;;
    check)
        mode_check
        ;;
    ensure)
        mode_ensure
        ;;
    reconcile)
        mode_reconcile
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
