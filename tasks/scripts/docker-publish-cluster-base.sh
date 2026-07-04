#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Publish the OpenShell cluster base image used by downstream deployment images.
# The source image must already contain the upstream cluster runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/container-engine.sh"

REGISTRY=${DOCKER_REGISTRY:?Set DOCKER_REGISTRY to push multi-arch images (e.g. ghcr.io/myorg)}
IMAGE_TAG=${IMAGE_TAG:-dev}
PLATFORMS=${DOCKER_PLATFORMS:-linux/amd64,linux/arm64}
BUILDER_NAME=${DOCKER_BUILDER:-multiarch}
SOURCE_IMAGE=${OPENSHELL_CLUSTER_SOURCE_IMAGE:-ghcr.io/tbuenger21/openshell-cluster:2026-06-11-agent-slices}
TAG_LATEST=${TAG_LATEST:-false}
EXTRA_DOCKER_TAGS_RAW=${EXTRA_DOCKER_TAGS:-}
EXTRA_TAGS=()

if [[ -n "${EXTRA_DOCKER_TAGS_RAW}" ]]; then
  EXTRA_DOCKER_TAGS_RAW=${EXTRA_DOCKER_TAGS_RAW//,/ }
  for tag in ${EXTRA_DOCKER_TAGS_RAW}; do
    [[ -n "${tag}" ]] && EXTRA_TAGS+=("${tag}")
  done
fi

if [[ "${TAG_LATEST}" == "true" ]]; then
  EXTRA_TAGS+=("latest")
fi

if ce_is_podman; then
  echo "Error: cluster base multi-arch publishing currently requires Docker buildx" >&2
  exit 1
fi

if ce buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
  ce buildx use "${BUILDER_NAME}" >/dev/null
else
  ce buildx create --name "${BUILDER_NAME}" --use --bootstrap >/dev/null
fi

TEMP_CONTEXT="$(mktemp -d)"
cleanup() {
  rm -rf "${TEMP_CONTEXT}"
}
trap cleanup EXIT

cat >"${TEMP_CONTEXT}/Dockerfile" <<'EOF'
ARG SOURCE_IMAGE
FROM ${SOURCE_IMAGE}

RUN rm -rf \
    /opt/potatostew/openshell-images \
    /usr/local/bin/potatostew-openshell-entrypoint.sh \
    /usr/local/bin/preload-openshell-images.sh \
    /usr/local/bin/potatostew-openshell-healthcheck.sh

ENV OPENSHELL_PRELOAD_IMAGE_ARCHIVES="" \
    OPENSHELL_PRELOAD_COMPLETE_FILE="" \
    OPENSHELL_REQUIRE_PRELOAD_COMPLETE=""

ENTRYPOINT ["/bin/sh", "/usr/local/bin/cluster-entrypoint.sh"]
HEALTHCHECK CMD /usr/local/bin/cluster-healthcheck.sh
EOF

image_ref="${REGISTRY}/cluster:${IMAGE_TAG}"
tags=("${image_ref}")
for tag in "${EXTRA_TAGS[@]}"; do
  [[ -n "${tag}" && "${tag}" != "${IMAGE_TAG}" ]] || continue
  tags+=("${REGISTRY}/cluster:${tag}")
done

build_cmd=(
  docker buildx build
  --platform "${PLATFORMS}"
  --build-arg "SOURCE_IMAGE=${SOURCE_IMAGE}"
  --file "${TEMP_CONTEXT}/Dockerfile"
  --push
)

for tag in "${tags[@]}"; do
  build_cmd+=(--tag "${tag}")
done

build_cmd+=("${TEMP_CONTEXT}")

echo "Publishing OpenShell cluster base image"
echo "  Source:    ${SOURCE_IMAGE}"
echo "  Platforms: ${PLATFORMS}"
for tag in "${tags[@]}"; do
  echo "  Tag:       ${tag}"
done
echo

"${build_cmd[@]}"

for tag in "${tags[@]}"; do
  docker manifest inspect "${tag}" >/dev/null
done

echo
echo "Done! Cluster base image pushed:"
for tag in "${tags[@]}"; do
  echo "  ${tag}"
done
