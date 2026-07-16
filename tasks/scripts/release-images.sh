#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# The release host publishes source-SHA candidates, tests those registry images,
# then signs and promotes explicitly requested release tags. It does not rely
# on GitHub Actions or a GitHub runner identity.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/image-release-metadata.sh"

CANDIDATE_TAG="${OPENSHELL_RELEASE_CANDIDATE_TAG:-}"
RELEASE_VERSION="${OPENSHELL_RELEASE_VERSION:-}"
RELEASE_ALIASES_RAW="${OPENSHELL_RELEASE_ALIASES:-}"
LEGACY_PROMOTION_TAG="${OPENSHELL_RELEASE_PROMOTE_TAG:-}"
REGISTRY="${DOCKER_REGISTRY:-ghcr.io/tbuenger21/openshell}"
PLATFORMS="${DOCKER_PLATFORMS:-linux/amd64,linux/arm64}"
DEFAULT_SANDBOX_IMAGE="$(awk '$1 == "sandboxImage:" { gsub(/"/, "", $2); print $2; exit }' "${ROOT}/deploy/helm/openshell/values.yaml")"
DEFAULT_CLUSTER_SANDBOX_IMAGE="$(awk '$1 == "sandboxImage:" { print $2; exit }' "${ROOT}/deploy/kube/manifests/openshell-helmchart.yaml")"
SANDBOX_IMAGE="${OPENSHELL_SANDBOX_IMAGE:-$DEFAULT_SANDBOX_IMAGE}"
COSIGN_KEY="${COSIGN_KEY:-}"
E2E_BASE_PORT="${OPENSHELL_RELEASE_E2E_BASE_PORT:-18080}"
REGISTRY_USERNAME="${OPENSHELL_REGISTRY_USERNAME:-}"
REGISTRY_PASSWORD="${OPENSHELL_REGISTRY_PASSWORD:-}"
OUTPUT_DIR="${OPENSHELL_RELEASE_OUTPUT_DIR:-}"
RELEASE_RECORDS_DIR="${ROOT}/releases"
VERSION_OUTPUT_DIR=""
RESUME="${OPENSHELL_RELEASE_RESUME:-0}"
REBUILD_CANDIDATE_MANIFEST=0
TEMP_ENV_FILE=""
E2E_CLUSTER_PREFIX=""
REQUESTED_RELEASE_ALIASES=()
RELEASE_ALIASES=()
PROMOTION_TAGS=()
PINNED_IMAGES=()
PINNED_SANDBOX_IMAGE=""

usage() {
  cat >&2 <<'EOF'
Usage: release-images.sh [options]

Build source-SHA OpenShell gateway, supervisor, and cluster candidates, run the
published-image E2E suites, then optionally sign and promote release tags. The
external sandbox base is resolved to a verified multi-platform digest and
recorded in release.env; it is not republished or signed as an OpenShell image.

Options:
  --tag TAG                 Exact sha-<OpenShell commit> candidate tag
  --version VERSION         Semantic version to promote after E2E and signing
  --alias TAG               Moving alias to promote after E2E and signing; repeatable
  --promote TAG             Deprecated: use --version or --alias
  --registry REPOSITORY     Registry namespace, e.g. ghcr.io/tbuenger21/openshell
  --platforms PLATFORMS     Comma-separated target platforms
  --e2e-base-port PORT      First host port for the three sequential E2E suites
  --output-dir DIR          Transient candidate manifest directory
  --resume                  Retest and promote the existing candidate manifest
  -h, --help                 Show this help

Use OPENSHELL_RELEASE_ALIASES as a comma-separated alias list. COSIGN_KEY is
required when --version or --alias is used. It may be a local key path or a KMS
URI. The host must already be authenticated to the target container registry and
have Docker, Buildx, mise, uv, Cargo, and an SSH client.

For a private registry, set both OPENSHELL_REGISTRY_USERNAME and
OPENSHELL_REGISTRY_PASSWORD so the E2E cluster can pull the gateway candidate.

OPENSHELL_SANDBOX_IMAGE may override the chart default for a release, but it
must be an immutable multi-platform digest reference.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      CANDIDATE_TAG="${2:-}"
      shift 2
      ;;
    --version)
      RELEASE_VERSION="${2:-}"
      shift 2
      ;;
    --alias)
      REQUESTED_RELEASE_ALIASES+=("${2:-}")
      shift 2
      ;;
    --promote)
      LEGACY_PROMOTION_TAG="${2:-}"
      shift 2
      ;;
    --registry)
      REGISTRY="${2:-}"
      shift 2
      ;;
    --platforms)
      PLATFORMS="${2:-}"
      shift 2
      ;;
    --e2e-base-port)
      E2E_BASE_PORT="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --resume)
      RESUME=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

add_release_alias() {
  local alias="$1"
  local existing_alias

  require_moving_image_alias "$alias" || exit 1
  if (( ${#RELEASE_ALIASES[@]} > 0 )); then
    for existing_alias in "${RELEASE_ALIASES[@]}"; do
      [[ "$existing_alias" == "$alias" ]] && return 0
    done
  fi
  RELEASE_ALIASES+=("$alias")
}

if (( ${#REQUESTED_RELEASE_ALIASES[@]} > 0 )); then
  for requested_alias in "${REQUESTED_RELEASE_ALIASES[@]}"; do
    add_release_alias "$requested_alias"
  done
fi

if [[ -n "$RELEASE_ALIASES_RAW" ]]; then
  IFS=',' read -r -a configured_aliases <<<"$RELEASE_ALIASES_RAW"
  for configured_alias in "${configured_aliases[@]}"; do
    add_release_alias "$configured_alias"
  done
fi

if [[ -n "$LEGACY_PROMOTION_TAG" ]]; then
  echo "warning: --promote is deprecated; use --version or --alias" >&2
  if is_moving_image_alias "$LEGACY_PROMOTION_TAG"; then
    add_release_alias "$LEGACY_PROMOTION_TAG"
  elif is_semantic_release_version "$LEGACY_PROMOTION_TAG"; then
    if [[ -n "$RELEASE_VERSION" && "$RELEASE_VERSION" != "$LEGACY_PROMOTION_TAG" ]]; then
      echo "--promote and --version specify different release versions" >&2
      exit 1
    fi
    RELEASE_VERSION="$LEGACY_PROMOTION_TAG"
  elif is_docker_image_tag "$LEGACY_PROMOTION_TAG"; then
    echo "warning: --promote accepts legacy fixed tags; prefer --version vMAJOR.MINOR.PATCH" >&2
    PROMOTION_TAGS+=("$LEGACY_PROMOTION_TAG")
  else
    echo "--promote must be a valid fixed tag or moving alias: $LEGACY_PROMOTION_TAG" >&2
    exit 1
  fi
fi

SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
if [[ -z "$SOURCE_REVISION" ]]; then
  echo "unable to determine the OpenShell source revision" >&2
  exit 1
fi
if [[ -z "$CANDIDATE_TAG" ]]; then
  CANDIDATE_TAG="sha-${SOURCE_REVISION}"
fi
require_source_sha_candidate_tag "$CANDIDATE_TAG" "$SOURCE_REVISION"
require_docker_image_tag "$CANDIDATE_TAG" "candidate tag" || exit 1

case "${OPENSHELL_ALLOW_MUTABLE_IMAGE_TAGS:-0}" in
  0|1) ;;
  *)
    echo "OPENSHELL_ALLOW_MUTABLE_IMAGE_TAGS must be 0 or 1" >&2
    exit 1
    ;;
esac
if [[ "${OPENSHELL_ALLOW_MUTABLE_IMAGE_TAGS:-0}" != "1" ]]; then
  case "$CANDIDATE_TAG" in
    dev|latest|edge|nightly)
      echo "candidate tag must be a source-SHA tag; use sha-<commit> or a version tag" >&2
      exit 1
      ;;
  esac
fi
if [[ -n "$RELEASE_VERSION" ]]; then
  require_semantic_release_version "$RELEASE_VERSION" || exit 1
  PROMOTION_TAGS+=("$RELEASE_VERSION")
fi
if (( ${#RELEASE_ALIASES[@]} > 0 )); then
  PROMOTION_TAGS+=("${RELEASE_ALIASES[@]}")
fi
if (( ${#PROMOTION_TAGS[@]} > 0 )); then
  for promotion_tag in "${PROMOTION_TAGS[@]}"; do
    if [[ "$promotion_tag" == "$CANDIDATE_TAG" ]]; then
      echo "release tag must differ from the source-SHA candidate tag" >&2
      exit 1
    fi
  done
fi
if [[ ! "$REGISTRY" =~ ^[A-Za-z0-9][A-Za-z0-9./:_-]*$ ]]; then
  echo "registry is invalid: $REGISTRY" >&2
  exit 1
fi
if [[ ! "$PLATFORMS" =~ ^linux/[A-Za-z0-9_/-]+(,linux/[A-Za-z0-9_/-]+)*$ ]]; then
  echo "platforms must be a comma-separated linux platform list" >&2
  exit 1
fi
if [[ -z "$DEFAULT_SANDBOX_IMAGE" || -z "$DEFAULT_CLUSTER_SANDBOX_IMAGE" || \
  "$DEFAULT_SANDBOX_IMAGE" != "$DEFAULT_CLUSTER_SANDBOX_IMAGE" ]]; then
  echo "the chart and cluster sandbox image defaults must match" >&2
  exit 1
fi
if [[ ! "$E2E_BASE_PORT" =~ ^[0-9]+$ ]] || (( E2E_BASE_PORT < 1024 || E2E_BASE_PORT > 65533 )); then
  echo "e2e base port must be between 1024 and 65533" >&2
  exit 1
fi
case "$RESUME" in
  0|1) ;;
  *)
    echo "OPENSHELL_RELEASE_RESUME must be 0 or 1" >&2
    exit 1
    ;;
esac
if [[ -n "$REGISTRY_USERNAME" && -z "$REGISTRY_PASSWORD" ]] || [[ -z "$REGISTRY_USERNAME" && -n "$REGISTRY_PASSWORD" ]]; then
  echo "set both OPENSHELL_REGISTRY_USERNAME and OPENSHELL_REGISTRY_PASSWORD for a private registry" >&2
  exit 1
fi
if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null || true)" ]]; then
  echo "OpenShell worktree is dirty: $ROOT" >&2
  echo "Release candidates must be built from a committed, clean revision." >&2
  exit 1
fi
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "the canonical release command requires a Linux release host" >&2
  exit 1
fi
SOURCE_URL="$(canonical_image_source_url "$ROOT")"

if ! command -v mise >/dev/null 2>&1; then
  echo "mise is required on the release host" >&2
  exit 1
fi

# Make tools declared in mise.toml available when this script is invoked
# directly, rather than relying on an interactive shell activation.
eval "$(mise activate bash)"

for command in docker git uv cargo helm ssh; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required on the release host" >&2
    exit 1
  fi
done
if ! docker buildx version >/dev/null 2>&1; then
  echo "docker buildx is required on the release host" >&2
  exit 1
fi
if (( ${#PROMOTION_TAGS[@]} > 0 )); then
  if ! command -v cosign >/dev/null 2>&1; then
    echo "cosign is required to promote tested release tags" >&2
    exit 1
  fi
  if [[ -z "$COSIGN_KEY" ]]; then
    echo "COSIGN_KEY is required to promote a tested release" >&2
    exit 1
  fi
  if [[ "$COSIGN_KEY" != *://* && ! -f "$COSIGN_KEY" ]]; then
    echo "COSIGN_KEY does not exist: $COSIGN_KEY" >&2
    exit 1
  fi
fi

registry_host="${REGISTRY%%/*}"
registry_namespace="${REGISTRY#*/}"
if [[ "$registry_namespace" == "$REGISTRY" ]]; then
  echo "registry must include a namespace, for example ghcr.io/tbuenger21/openshell" >&2
  exit 1
fi

COMPONENTS=(gateway supervisor cluster)
require_new_candidate_images() {
  local component

  for component in "${COMPONENTS[@]}"; do
    require_new_image_ref "${REGISTRY}/${component}:${CANDIDATE_TAG}"
  done
}

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${ROOT}/dist/releases/${CANDIDATE_TAG}"
fi
mkdir -p "$(dirname "$OUTPUT_DIR")"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" && pwd)/$(basename "$OUTPUT_DIR")"
RELEASE_ENV_PATH="${OUTPUT_DIR}/release.env"
if [[ -n "$RELEASE_VERSION" ]]; then
  VERSION_OUTPUT_DIR="${RELEASE_RECORDS_DIR}/${RELEASE_VERSION}"
fi

if [[ "$RESUME" == "1" ]]; then
  if [[ -f "$RELEASE_ENV_PATH" ]]; then
    :
  elif [[ ! -e "$OUTPUT_DIR" ]]; then
    # A host interruption can occur after candidates are published but before
    # their atomic manifest directory is renamed into place. Rebuild it from
    # the candidate tags, then retest the newly snapshotted digests.
    REBUILD_CANDIDATE_MANIFEST=1
  else
    echo "release manifest is incomplete for --resume: $OUTPUT_DIR" >&2
    exit 1
  fi
else
  if [[ -e "$OUTPUT_DIR" ]]; then
    echo "candidate manifest directory already exists: $OUTPUT_DIR" >&2
    echo "Use --resume to retest/promote that exact candidate instead of replacing it." >&2
    exit 1
  fi
  if [[ -n "$VERSION_OUTPUT_DIR" && -e "$VERSION_OUTPUT_DIR" ]]; then
    echo "version release record already exists: $VERSION_OUTPUT_DIR" >&2
    exit 1
  fi
  # Candidate tags are never reused. Version tags are handled after their
  # expected digest is known so interrupted promotions can be resumed safely.
  require_new_candidate_images
fi

E2E_CLUSTER_PREFIX="release-$(printf '%s' "${CANDIDATE_TAG#sha-}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
if [[ -z "$E2E_CLUSTER_PREFIX" ]]; then
  echo "candidate tag cannot produce an E2E cluster name" >&2
  exit 1
fi
E2E_CLUSTER_PREFIX="${E2E_CLUSTER_PREFIX:0:55}"

E2E_REGISTRY_AUTH=()
if [[ -n "$REGISTRY_USERNAME" ]]; then
  E2E_REGISTRY_AUTH=(
    "OPENSHELL_REGISTRY_USERNAME=$REGISTRY_USERNAME"
    "OPENSHELL_REGISTRY_PASSWORD=$REGISTRY_PASSWORD"
  )
fi

cleanup_cluster() {
  local cluster_name="$1"
  docker rm -f "openshell-cluster-${cluster_name}" >/dev/null 2>&1 || true
  docker volume rm "openshell-cluster-${cluster_name}" >/dev/null 2>&1 || true
}

cleanup() {
  cleanup_cluster "${E2E_CLUSTER_PREFIX}-python"
  cleanup_cluster "${E2E_CLUSTER_PREFIX}-rust"
  cleanup_cluster "${E2E_CLUSTER_PREFIX}-resume"
  if [[ -n "$TEMP_ENV_FILE" ]]; then
    rm -f "$TEMP_ENV_FILE"
  fi
}
trap cleanup EXIT

image_digest() {
  local image_ref="$1"
  local inspection digest

  inspection="$(docker buildx imagetools inspect "$image_ref")"
  digest="$(printf '%s\n' "$inspection" | awk '/^[[:space:]]*Digest:/ { print $2; exit }')"
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "could not resolve a manifest digest for $image_ref" >&2
    return 1
  fi
  printf '%s\n' "$digest"
}

verify_tag() {
  local image_ref="$1"
  local manifest_json

  manifest_json="$(docker manifest inspect "$image_ref")"
  MANIFEST_JSON="$manifest_json" uv run python - "$image_ref" "$PLATFORMS" <<'PY'
import json
import os
import sys

image_ref, platforms_raw = sys.argv[1:]
manifest = json.loads(os.environ["MANIFEST_JSON"])
available = {
    f"{entry.get('platform', {}).get('os', 'unknown')}/"
    f"{entry.get('platform', {}).get('architecture', 'unknown')}"
    for entry in manifest.get("manifests", [])
}
required = {platform.strip() for platform in platforms_raw.split(",") if platform.strip()}
missing = sorted(required - available)

if not available:
    raise SystemExit(f"{image_ref}: expected a multi-platform manifest list")
if missing:
    raise SystemExit(f"{image_ref}: missing required platforms: {', '.join(missing)}")

print(f"{image_ref}: verified platforms: {', '.join(sorted(available))}")
PY
}

resolve_pinned_sandbox_image() {
  local image_ref="$1"
  local expected_digest actual_digest

  case "$image_ref" in
    *@sha256:*) ;;
    *)
      echo "sandbox image must be an immutable digest reference: $image_ref" >&2
      return 1
      ;;
  esac
  if [[ "${image_ref%@*}" == "$image_ref" || \
    ! "${image_ref#*@}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "sandbox image has an invalid digest reference: $image_ref" >&2
    return 1
  fi

  verify_tag "$image_ref"
  expected_digest="${image_ref#*@}"
  actual_digest="$(image_digest "$image_ref")"
  if [[ "$actual_digest" != "$expected_digest" ]]; then
    echo "sandbox image digest changed: expected $expected_digest, got $actual_digest" >&2
    return 1
  fi
  PINNED_SANDBOX_IMAGE="${image_ref%@*}@${actual_digest}"
}

validate_pinned_image() {
  local component="$1"
  local image_ref="$2"
  local expected_ref="${REGISTRY}/${component}"
  local expected_digest actual_digest

  if [[ "$image_ref" != "${expected_ref}@sha256:"* ]] || \
    [[ ! "${image_ref#*@}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "release manifest has an invalid ${component} image: $image_ref" >&2
    return 1
  fi
  expected_digest="${image_ref#*@}"
  actual_digest="$(image_digest "$image_ref")"
  if [[ "$actual_digest" != "$expected_digest" ]]; then
    echo "release manifest digest changed for ${component}: expected ${expected_digest}, got ${actual_digest}" >&2
    return 1
  fi
}

write_release_manifest() {
  local index component output_parent output_name temporary_output_dir temporary_manifest

  if [[ -e "$OUTPUT_DIR" ]]; then
    echo "refusing to replace an existing release manifest directory: $OUTPUT_DIR" >&2
    return 1
  fi
  if [[ -z "$PINNED_SANDBOX_IMAGE" ]]; then
    echo "sandbox image must be resolved before writing a release manifest" >&2
    return 1
  fi
  output_parent="$(dirname "$OUTPUT_DIR")"
  output_name="$(basename "$OUTPUT_DIR")"
  temporary_output_dir="$(mktemp -d "${output_parent}/.${output_name}.tmp.XXXXXX")"
  temporary_manifest="${temporary_output_dir}/release.env.tmp"
  {
    printf 'OPENSHELL_RELEASE_SCHEMA_VERSION=2\n'
    printf 'OPENSHELL_RELEASE_CANDIDATE_TAG=%s\n' "$CANDIDATE_TAG"
    printf 'OPENSHELL_RELEASE_VERSION=%s\n' "$RELEASE_VERSION"
    printf 'OPENSHELL_SOURCE_REVISION=%s\n' "$SOURCE_REVISION"
    printf 'OPENSHELL_RELEASE_REGISTRY=%s\n' "$REGISTRY"
    printf 'OPENSHELL_RELEASE_PLATFORMS=%s\n' "$PLATFORMS"
    printf 'OPENSHELL_SANDBOX_IMAGE=%s\n' "$PINNED_SANDBOX_IMAGE"
    for index in "${!COMPONENTS[@]}"; do
      component="${COMPONENTS[$index]}"
      printf 'OPENSHELL_%s_IMAGE=%s\n' "$(printf '%s' "$component" | tr '[:lower:]' '[:upper:]')" "${PINNED_IMAGES[$index]}"
    done
  } >"$temporary_manifest"
  chmod 0644 "$temporary_manifest"
  if ! mv "$temporary_manifest" "${temporary_output_dir}/release.env" || \
    ! mv "$temporary_output_dir" "$OUTPUT_DIR"; then
    rm -f "$temporary_manifest" "${temporary_output_dir}/release.env"
    rmdir "$temporary_output_dir" 2>/dev/null || true
    echo "unable to publish release manifest directory: $OUTPUT_DIR" >&2
    return 1
  fi
  echo "Wrote release manifest: $RELEASE_ENV_PATH"
}

load_release_manifest() {
  local index component image_variable image_ref
  local manifest_schema_version manifest_candidate_tag manifest_release_version
  local manifest_source_revision manifest_registry manifest_platforms manifest_sandbox_image
  local -a manifest_keys

  manifest_keys=(
    OPENSHELL_RELEASE_SCHEMA_VERSION
    OPENSHELL_RELEASE_CANDIDATE_TAG
    OPENSHELL_RELEASE_VERSION
    OPENSHELL_SOURCE_REVISION
    OPENSHELL_RELEASE_REGISTRY
    OPENSHELL_RELEASE_PLATFORMS
    OPENSHELL_SANDBOX_IMAGE
  )
  for component in "${COMPONENTS[@]}"; do
    manifest_keys+=("OPENSHELL_$(printf '%s' "$component" | tr '[:lower:]' '[:upper:]')_IMAGE")
  done
  validate_release_manifest_records "$RELEASE_ENV_PATH" "${manifest_keys[@]}" || return 1
  if ! manifest_schema_version="$(read_release_manifest_value "$RELEASE_ENV_PATH" OPENSHELL_RELEASE_SCHEMA_VERSION)" || \
    ! manifest_candidate_tag="$(read_release_manifest_value "$RELEASE_ENV_PATH" OPENSHELL_RELEASE_CANDIDATE_TAG)" || \
    ! manifest_release_version="$(read_release_manifest_value "$RELEASE_ENV_PATH" OPENSHELL_RELEASE_VERSION)" || \
    ! manifest_source_revision="$(read_release_manifest_value "$RELEASE_ENV_PATH" OPENSHELL_SOURCE_REVISION)" || \
    ! manifest_registry="$(read_release_manifest_value "$RELEASE_ENV_PATH" OPENSHELL_RELEASE_REGISTRY)" || \
    ! manifest_platforms="$(read_release_manifest_value "$RELEASE_ENV_PATH" OPENSHELL_RELEASE_PLATFORMS)" || \
    ! manifest_sandbox_image="$(read_release_manifest_value "$RELEASE_ENV_PATH" OPENSHELL_SANDBOX_IMAGE)"; then
    return 1
  fi
  if [[ "$manifest_schema_version" != "2" || \
    "$manifest_candidate_tag" != "$CANDIDATE_TAG" || \
    "$manifest_source_revision" != "$SOURCE_REVISION" || \
    "$manifest_registry" != "$REGISTRY" || \
    "$manifest_platforms" != "$PLATFORMS" || \
    "$manifest_release_version" != "$RELEASE_VERSION" ]]; then
    echo "release manifest does not match this requested release" >&2
    return 1
  fi
  if [[ "$manifest_sandbox_image" != "$SANDBOX_IMAGE" ]]; then
    echo "release manifest sandbox image does not match this requested release" >&2
    return 1
  fi
  resolve_pinned_sandbox_image "$manifest_sandbox_image"

  PINNED_IMAGES=()
  for index in "${!COMPONENTS[@]}"; do
    component="${COMPONENTS[$index]}"
    image_variable="OPENSHELL_$(printf '%s' "$component" | tr '[:lower:]' '[:upper:]')_IMAGE"
    if ! image_ref="$(read_release_manifest_value "$RELEASE_ENV_PATH" "$image_variable")"; then
      return 1
    fi
    validate_pinned_image "$component" "$image_ref"
    PINNED_IMAGES+=("$image_ref")
  done
}

write_version_release_record() {
  local version_manifest temporary_version_dir

  [[ -n "$VERSION_OUTPUT_DIR" ]] || return 0
  mkdir -p "$(dirname "$VERSION_OUTPUT_DIR")"
  version_manifest="${VERSION_OUTPUT_DIR}/release.env"
  if [[ -e "$VERSION_OUTPUT_DIR" ]]; then
    if [[ ! -f "$version_manifest" ]] || ! cmp -s "$RELEASE_ENV_PATH" "$version_manifest"; then
      echo "version release record conflicts with this candidate: $VERSION_OUTPUT_DIR" >&2
      return 1
    fi
    echo "Reusing version release record: $version_manifest"
    return 0
  fi
  temporary_version_dir="$(mktemp -d "$(dirname "$VERSION_OUTPUT_DIR")/.$(basename "$VERSION_OUTPUT_DIR").tmp.XXXXXX")"
  version_manifest="${temporary_version_dir}/release.env"
  if ! install -m 0644 "$RELEASE_ENV_PATH" "$version_manifest"; then
    rm -f "$version_manifest"
    rmdir "$temporary_version_dir" 2>/dev/null || true
    echo "unable to prepare version release record: $VERSION_OUTPUT_DIR" >&2
    return 1
  fi
  if ! mv "$temporary_version_dir" "$VERSION_OUTPUT_DIR"; then
    rm -f "$version_manifest"
    rmdir "$temporary_version_dir" 2>/dev/null || true
    echo "unable to publish version release record: $VERSION_OUTPUT_DIR" >&2
    return 1
  fi
  echo "Wrote version release record: ${VERSION_OUTPUT_DIR}/release.env"
}

resolve_candidate_images() {
  local component image_ref image_repo

  PINNED_IMAGES=()
  for component in "${COMPONENTS[@]}"; do
    image_ref="${REGISTRY}/${component}:${CANDIDATE_TAG}"
    image_repo="${image_ref%:*}"
    verify_tag "$image_ref"
    PINNED_IMAGES+=("${image_repo}@$(image_digest "$image_ref")")
  done
  resolve_pinned_sandbox_image "$SANDBOX_IMAGE"
  write_release_manifest
}

verify_tag_matches_pinned_image() {
  local tag_ref="$1"
  local pinned_image="$2"
  local expected_digest="${pinned_image#*@}"
  local actual_digest

  verify_tag "$tag_ref"
  actual_digest="$(image_digest "$tag_ref")"
  if [[ "$actual_digest" != "$expected_digest" ]]; then
    echo "promotion did not preserve the tested digest for $tag_ref" >&2
    return 1
  fi
}

promote_pinned_image() {
  local tag_ref="$1"
  local pinned_image="$2"
  local promotion_tag="$3"
  local inspection_status=0
  local actual_digest expected_digest

  image_ref_exists "$tag_ref" || inspection_status=$?
  if [[ "$inspection_status" -eq 0 ]] && ! is_moving_image_alias "$promotion_tag"; then
    expected_digest="${pinned_image#*@}"
    actual_digest="$(image_digest "$tag_ref")"
    if [[ "$actual_digest" != "$expected_digest" ]]; then
      echo "refusing to replace fixed release tag with a different digest: $tag_ref" >&2
      return 1
    fi
    echo "Fixed release tag already points at the tested digest: $tag_ref"
    verify_tag_matches_pinned_image "$tag_ref" "$pinned_image"
    return 0
  fi
  if [[ "$inspection_status" -ne 0 && "$inspection_status" -ne 1 ]]; then
    return "$inspection_status"
  fi

  docker buildx imagetools create \
    --prefer-index=false \
    --tag "$tag_ref" \
    "$pinned_image"
  verify_tag_matches_pinned_image "$tag_ref" "$pinned_image"
}

run_e2e_suite() {
  local suite="$1"
  local port="$2"
  local cluster_name="${E2E_CLUSTER_PREFIX}-${suite}"
  shift 2

  cleanup_cluster "$cluster_name"
  : >"$TEMP_ENV_FILE"
  env \
    "OPENSHELL_ENV_FILE=$TEMP_ENV_FILE" \
    "IMAGE_TAG=$CANDIDATE_TAG" \
    "OPENSHELL_REGISTRY=$REGISTRY" \
    "OPENSHELL_REGISTRY_HOST=$registry_host" \
    "OPENSHELL_REGISTRY_NAMESPACE=$registry_namespace" \
    "GATEWAY_HOST=127.0.0.1" \
    "GATEWAY_PORT=$port" \
    "CLUSTER_NAME=$cluster_name" \
    "OPENSHELL_GATEWAY=$cluster_name" \
    "SKIP_IMAGE_PUSH=1" \
    "SKIP_CLUSTER_IMAGE_BUILD=1" \
    "OPENSHELL_GATEWAY_IMAGE=${PINNED_IMAGES[0]}" \
    "OPENSHELL_SANDBOX_IMAGE=${PINNED_SANDBOX_IMAGE}" \
    "OPENSHELL_CLUSTER_IMAGE=${PINNED_IMAGES[2]}" \
    "${E2E_REGISTRY_AUTH[@]}" \
    mise run --no-deps --skip-deps cluster

  env \
    "OPENSHELL_ENV_FILE=$TEMP_ENV_FILE" \
    "IMAGE_TAG=$CANDIDATE_TAG" \
    "OPENSHELL_REGISTRY=$REGISTRY" \
    "OPENSHELL_REGISTRY_HOST=$registry_host" \
    "OPENSHELL_REGISTRY_NAMESPACE=$registry_namespace" \
    "GATEWAY_HOST=127.0.0.1" \
    "GATEWAY_PORT=$port" \
    "CLUSTER_NAME=$cluster_name" \
    "OPENSHELL_GATEWAY=$cluster_name" \
    "SKIP_IMAGE_PUSH=1" \
    "SKIP_CLUSTER_IMAGE_BUILD=1" \
    "OPENSHELL_GATEWAY_IMAGE=${PINNED_IMAGES[0]}" \
    "OPENSHELL_SANDBOX_IMAGE=${PINNED_SANDBOX_IMAGE}" \
    "OPENSHELL_CLUSTER_IMAGE=${PINNED_IMAGES[2]}" \
    "OPENSHELL_E2E_EXPECT_PRODUCTION_SETTINGS=1" \
    "${E2E_REGISTRY_AUTH[@]}" \
    "$@"

  cleanup_cluster "$cluster_name"
}

cd "$ROOT"
if [[ "$RESUME" == "1" ]]; then
  echo "Resuming OpenShell release candidate"
else
  echo "Publishing OpenShell release candidate"
fi
echo "  Candidate tag: $CANDIDATE_TAG"
echo "  Registry:      $REGISTRY"
echo "  Platforms:     $PLATFORMS"
echo "  Sandbox base:  $SANDBOX_IMAGE"
echo "  Release version: ${RELEASE_VERSION:-<none>}"
if (( ${#RELEASE_ALIASES[@]} == 0 )); then
  echo "  Moving aliases:  <none>"
else
  echo "  Moving aliases:  ${RELEASE_ALIASES[*]}"
fi
echo

if [[ "$RESUME" == "1" ]]; then
  if [[ "$REBUILD_CANDIDATE_MANIFEST" == "1" ]]; then
    echo "Rebuilding missing candidate manifest from published candidate images"
    resolve_candidate_images
  fi
  load_release_manifest
else
  EXTRA_CARGO_FEATURES="" \
  OPENSHELL_IMAGE_SOURCE_REVISION="$SOURCE_REVISION" \
  OPENSHELL_IMAGE_SOURCE_URL="$SOURCE_URL" \
  DOCKER_REGISTRY="$REGISTRY" \
  IMAGE_TAG="$CANDIDATE_TAG" \
  DOCKER_PLATFORMS="$PLATFORMS" \
  EXTRA_DOCKER_TAGS="" \
  TAG_LATEST=false \
  tasks/scripts/docker-publish-multiarch.sh
  resolve_candidate_images
  load_release_manifest
fi

TEMP_ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/openshell-release-e2e.XXXXXX")"
uv sync --frozen
mise run --no-deps python:proto
cargo build -p openshell-cli --features openshell-core/dev-settings
export PATH="${ROOT}/target/debug:${PATH}"

run_e2e_suite python "$E2E_BASE_PORT" mise run --no-deps --skip-deps e2e:python
run_e2e_suite rust "$((E2E_BASE_PORT + 1))" \
  cargo test --manifest-path e2e/rust/Cargo.toml --features e2e -- --skip gateway_resume_scenarios
run_e2e_suite resume "$((E2E_BASE_PORT + 2))" \
  cargo test --manifest-path e2e/rust/Cargo.toml --features e2e --test gateway_resume

if (( ${#PROMOTION_TAGS[@]} == 0 )); then
  echo
  echo "Candidate passed published-image E2E. No release tags were promoted."
  exit 0
fi

echo
echo "Signing tested candidate digests"
for image_ref in "${PINNED_IMAGES[@]}"; do
  cosign sign --yes --key "$COSIGN_KEY" "$image_ref"
done

echo
echo "Promoting tested release tags"
for promotion_tag in "${PROMOTION_TAGS[@]}"; do
  echo "  Tag: $promotion_tag"
  for index in "${!COMPONENTS[@]}"; do
    component="${COMPONENTS[$index]}"
    promote_pinned_image \
      "${REGISTRY}/${component}:${promotion_tag}" \
      "${PINNED_IMAGES[$index]}" \
      "$promotion_tag"
  done
done

write_version_release_record

echo
echo "Release tags promoted after published-image E2E and Cosign signing."
if [[ -n "$VERSION_OUTPUT_DIR" ]]; then
  echo "Version release record: ${VERSION_OUTPUT_DIR}/release.env"
  echo "Commit the version record before another release: git add releases/${RELEASE_VERSION}"
fi
