#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build multi-arch gateway, supervisor, and cluster images and push to a container registry.
# Requires DOCKER_REGISTRY to be set (e.g. ghcr.io/myorg).

set -euo pipefail

REGISTRY=${DOCKER_REGISTRY:?Set DOCKER_REGISTRY to push multi-arch images (e.g. ghcr.io/myorg)}
IMAGE_TAG=${IMAGE_TAG:-}
PLATFORMS=${DOCKER_PLATFORMS:-linux/amd64,linux/arm64}
TAG_LATEST=${TAG_LATEST:-false}
EXTRA_DOCKER_TAGS_RAW=${EXTRA_DOCKER_TAGS:-}
EXTRA_TAGS=()

if [[ -z "${IMAGE_TAG}" ]]; then
  SOURCE_REVISION=$(git rev-parse HEAD 2>/dev/null || true)
  if [[ -z "${SOURCE_REVISION}" ]]; then
    echo "unable to determine image source revision; set IMAGE_TAG" >&2
    exit 1
  fi
  IMAGE_TAG="sha-${SOURCE_REVISION}"
fi

case "${OPENSHELL_ALLOW_MUTABLE_IMAGE_TAGS:-0}" in
  0|1) ;;
  *)
    echo "OPENSHELL_ALLOW_MUTABLE_IMAGE_TAGS must be 0 or 1" >&2
    exit 1
    ;;
esac

if [[ "${OPENSHELL_ALLOW_MUTABLE_IMAGE_TAGS:-0}" != "1" ]]; then
  case "${IMAGE_TAG}" in
    dev|latest|edge|nightly)
      echo "IMAGE_TAG must be immutable; use sha-<commit> or a version tag" >&2
      echo "Set OPENSHELL_ALLOW_MUTABLE_IMAGE_TAGS=1 only for an explicit development publish." >&2
      exit 1
      ;;
  esac
fi

if [[ "${TAG_LATEST}" != "true" && "${TAG_LATEST}" != "false" ]]; then
  echo "TAG_LATEST must be true or false" >&2
  exit 1
fi

case "${OPENSHELL_ALLOW_UNVERIFIED_IMAGE_ALIASES:-0}" in
  0|1) ;;
  *)
    echo "OPENSHELL_ALLOW_UNVERIFIED_IMAGE_ALIASES must be 0 or 1" >&2
    exit 1
    ;;
esac

if [[ ( -n "${EXTRA_DOCKER_TAGS_RAW}" || "${TAG_LATEST}" == "true" ) && "${OPENSHELL_ALLOW_UNVERIFIED_IMAGE_ALIASES:-0}" != "1" ]]; then
  echo "image aliases must be promoted by tasks/scripts/release-images.sh after published-image E2E" >&2
  echo "Set OPENSHELL_ALLOW_UNVERIFIED_IMAGE_ALIASES=1 only for an explicit non-release publish." >&2
  exit 1
fi

if [[ -n "${EXTRA_DOCKER_TAGS_RAW}" ]]; then
  EXTRA_DOCKER_TAGS_RAW=${EXTRA_DOCKER_TAGS_RAW//,/ }
  for tag in ${EXTRA_DOCKER_TAGS_RAW}; do
    if [[ "${tag}" == "latest" ]]; then
      echo "use TAG_LATEST=true to promote the latest alias; do not include it in EXTRA_DOCKER_TAGS" >&2
      exit 1
    fi
    [[ -n "${tag}" ]] && EXTRA_TAGS+=("${tag}")
  done
fi

BUILDER_NAME=${DOCKER_BUILDER:-multiarch}
if docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
  echo "Using existing buildx builder: ${BUILDER_NAME}"
else
  echo "Creating multi-platform buildx builder: ${BUILDER_NAME}..."
  docker buildx create --name "${BUILDER_NAME}" --driver docker-container --bootstrap
fi

export DOCKER_BUILDER="${BUILDER_NAME}"
export DOCKER_PLATFORM="${PLATFORMS}"
export DOCKER_PUSH=1
export IMAGE_REGISTRY="${REGISTRY}"

echo "Building multi-arch gateway image..."
tasks/scripts/docker-build-image.sh gateway

echo
echo "Building multi-arch supervisor image..."
tasks/scripts/docker-build-image.sh supervisor

echo
echo "Building multi-arch cluster image..."
tasks/scripts/docker-build-image.sh cluster

TAGS_TO_APPLY=("${EXTRA_TAGS[@]}")
if [[ "${TAG_LATEST}" == "true" ]]; then
  TAGS_TO_APPLY+=("latest")
fi

if [[ ${#TAGS_TO_APPLY[@]} -gt 0 ]]; then
  for component in gateway supervisor cluster; do
    full_image="${REGISTRY}/${component}"
    for tag in "${TAGS_TO_APPLY[@]}"; do
      [[ "${tag}" == "${IMAGE_TAG}" ]] && continue
      echo "Tagging ${full_image}:${tag}..."
      docker buildx imagetools create \
        --prefer-index=false \
        -t "${full_image}:${tag}" \
        "${full_image}:${IMAGE_TAG}"
    done
  done
fi

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

for component in gateway supervisor cluster; do
  full_image="${REGISTRY}/${component}"
  verify_tag "${full_image}:${IMAGE_TAG}"
  for tag in "${TAGS_TO_APPLY[@]}"; do
    [[ "${tag}" == "${IMAGE_TAG}" ]] && continue
    verify_tag "${full_image}:${tag}"
  done
done

echo
echo "Done! Multi-arch images pushed to ${REGISTRY}:"
echo "  ${REGISTRY}/gateway:${IMAGE_TAG}"
echo "  ${REGISTRY}/supervisor:${IMAGE_TAG}"
echo "  ${REGISTRY}/cluster:${IMAGE_TAG}"
if [[ "${TAG_LATEST}" == "true" ]]; then
  echo "  (all also tagged :latest)"
fi
if [[ ${#EXTRA_TAGS[@]} -gt 0 ]]; then
  echo "  (all also tagged: ${EXTRA_TAGS[*]})"
fi
