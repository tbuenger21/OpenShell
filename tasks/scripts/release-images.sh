#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# The release host publishes immutable candidates, tests those registry images,
# then signs and promotes only an explicitly requested alias. It does not rely
# on GitHub Actions or a GitHub runner identity.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/image-release-metadata.sh"

CANDIDATE_TAG="${OPENSHELL_RELEASE_CANDIDATE_TAG:-}"
PROMOTION_TAG="${OPENSHELL_RELEASE_PROMOTE_TAG:-}"
REGISTRY="${DOCKER_REGISTRY:-ghcr.io/tbuenger21/openshell}"
PLATFORMS="${DOCKER_PLATFORMS:-linux/amd64,linux/arm64}"
COSIGN_KEY="${COSIGN_KEY:-}"
E2E_BASE_PORT="${OPENSHELL_RELEASE_E2E_BASE_PORT:-18080}"
REGISTRY_USERNAME="${OPENSHELL_REGISTRY_USERNAME:-}"
REGISTRY_PASSWORD="${OPENSHELL_REGISTRY_PASSWORD:-}"
TEMP_ENV_FILE=""
E2E_CLUSTER_PREFIX=""

usage() {
  cat >&2 <<'EOF'
Usage: release-images.sh [options]

Build immutable OpenShell gateway, supervisor, and cluster candidates, run the
published-image E2E suites, then optionally sign and promote an alias.

Options:
  --tag TAG               Exact sha-<OpenShell commit> candidate tag
  --promote TAG           Alias to promote after E2E and Cosign signing
  --registry REPOSITORY   Registry namespace, e.g. ghcr.io/tbuenger21/openshell
  --platforms PLATFORMS   Comma-separated target platforms
  --e2e-base-port PORT    First host port for the three sequential E2E suites
  -h, --help              Show this help

COSIGN_KEY is required only with --promote. It may be a local key path or a
KMS URI. The host must already be authenticated to the target container
registry and have Docker, Buildx, mise, uv, Cargo, and an SSH client.

For a private registry, set both OPENSHELL_REGISTRY_USERNAME and
OPENSHELL_REGISTRY_PASSWORD so the E2E cluster can pull the gateway candidate.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      CANDIDATE_TAG="${2:-}"
      shift 2
      ;;
    --promote)
      PROMOTION_TAG="${2:-}"
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

SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
if [[ -z "$SOURCE_REVISION" ]]; then
  echo "unable to determine the OpenShell source revision" >&2
  exit 1
fi
if [[ -z "$CANDIDATE_TAG" ]]; then
  CANDIDATE_TAG="sha-${SOURCE_REVISION}"
fi
require_source_sha_candidate_tag "$CANDIDATE_TAG" "$SOURCE_REVISION"

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
      echo "candidate tag must be immutable; use sha-<commit> or a version tag" >&2
      exit 1
      ;;
  esac
fi
if [[ -n "$PROMOTION_TAG" && ! "$PROMOTION_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "promotion tag may contain only letters, digits, dots, underscores, and hyphens" >&2
  exit 1
fi
if [[ "$PROMOTION_TAG" == "$CANDIDATE_TAG" ]]; then
  echo "promotion tag must differ from the immutable candidate tag" >&2
  exit 1
fi
if [[ ! "$REGISTRY" =~ ^[A-Za-z0-9][A-Za-z0-9./:_-]*$ ]]; then
  echo "registry is invalid: $REGISTRY" >&2
  exit 1
fi
if [[ ! "$PLATFORMS" =~ ^linux/[A-Za-z0-9_/-]+(,linux/[A-Za-z0-9_/-]+)*$ ]]; then
  echo "platforms must be a comma-separated linux platform list" >&2
  exit 1
fi
if [[ ! "$E2E_BASE_PORT" =~ ^[0-9]+$ ]] || (( E2E_BASE_PORT < 1024 || E2E_BASE_PORT > 65533 )); then
  echo "e2e base port must be between 1024 and 65533" >&2
  exit 1
fi
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

for command in docker git mise uv cargo ssh; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required on the release host" >&2
    exit 1
  fi
done
if ! docker buildx version >/dev/null 2>&1; then
  echo "docker buildx is required on the release host" >&2
  exit 1
fi
if [[ -n "$PROMOTION_TAG" ]]; then
  if ! command -v cosign >/dev/null 2>&1; then
    echo "cosign is required to promote a tested release" >&2
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

require_available_promotion_alias() {
  local component

  [[ -n "$PROMOTION_TAG" ]] || return 0
  for component in "${COMPONENTS[@]}"; do
    require_new_release_alias "${REGISTRY}/${component}:${PROMOTION_TAG}" "$PROMOTION_TAG"
  done
}

# Detect ordinary operator mistakes before any image is published. The release
# registry must also enforce immutable candidate and version tags to close the
# race between this check and the push.
require_new_candidate_images
require_available_promotion_alias

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
    "OPENSHELL_CLUSTER_IMAGE=${REGISTRY}/cluster:${CANDIDATE_TAG}" \
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
    "OPENSHELL_CLUSTER_IMAGE=${REGISTRY}/cluster:${CANDIDATE_TAG}" \
    "${E2E_REGISTRY_AUTH[@]}" \
    "$@"

  cleanup_cluster "$cluster_name"
}

cd "$ROOT"
echo "Publishing OpenShell release candidate"
echo "  Candidate tag: $CANDIDATE_TAG"
echo "  Registry:      $REGISTRY"
echo "  Platforms:     $PLATFORMS"
echo "  Promote tag:   ${PROMOTION_TAG:-<none>}"
echo

OPENSHELL_IMAGE_SOURCE_REVISION="$SOURCE_REVISION" \
OPENSHELL_IMAGE_SOURCE_URL="$SOURCE_URL" \
DOCKER_REGISTRY="$REGISTRY" \
IMAGE_TAG="$CANDIDATE_TAG" \
DOCKER_PLATFORMS="$PLATFORMS" \
EXTRA_DOCKER_TAGS="" \
TAG_LATEST=false \
tasks/scripts/docker-publish-multiarch.sh

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

if [[ -z "$PROMOTION_TAG" ]]; then
  echo
  echo "Candidate passed published-image E2E. No alias was promoted."
  exit 0
fi

PINNED_IMAGES=()
for component in "${COMPONENTS[@]}"; do
  image_ref="${REGISTRY}/${component}:${CANDIDATE_TAG}"
  image_repo="${image_ref%:*}"
  PINNED_IMAGES+=("${image_repo}@$(image_digest "$image_ref")")
done

echo
echo "Signing tested candidate digests"
for image_ref in "${PINNED_IMAGES[@]}"; do
  cosign sign --yes --key "$COSIGN_KEY" "$image_ref"
done

echo
echo "Promoting tested alias: $PROMOTION_TAG"
require_available_promotion_alias
for index in "${!COMPONENTS[@]}"; do
  component="${COMPONENTS[$index]}"
  docker buildx imagetools create \
    --prefer-index=false \
    --tag "${REGISTRY}/${component}:${PROMOTION_TAG}" \
    "${PINNED_IMAGES[$index]}"
  verify_tag "${REGISTRY}/${component}:${PROMOTION_TAG}"
done

echo
echo "Release alias promoted after published-image E2E and Cosign signing."
