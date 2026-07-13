#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build the CI Docker image (deploy/docker/Dockerfile.ci).
# This is a standalone build, separate from the main image build graph.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/image-release-metadata.sh"

OUTPUT_ARGS=(--load)
if [[ "${DOCKER_PUSH:-}" == "1" ]]; then
  OUTPUT_ARGS=(--push)
elif [[ "${DOCKER_PLATFORM:-}" == *","* ]]; then
  OUTPUT_ARGS=(--push)
fi

BUILDER_ARGS=()
if [[ -n "${DOCKER_BUILDER:-}" ]]; then
  BUILDER_ARGS=(--builder "${DOCKER_BUILDER}")
fi

PLATFORM_ARGS=()
if [[ -n "${DOCKER_PLATFORM:-}" ]]; then
  PLATFORM_ARGS=(--platform "${DOCKER_PLATFORM}")
fi

METADATA_ARGS=()
SOURCE_REVISION="${OPENSHELL_IMAGE_SOURCE_REVISION:-$(git rev-parse HEAD 2>/dev/null || true)}"
SOURCE_URL="$(canonical_image_source_url "$PWD" 2>/dev/null || true)"
if [[ -n "${SOURCE_REVISION}" ]]; then
  METADATA_ARGS+=(--label "org.opencontainers.image.revision=${SOURCE_REVISION}")
fi
if [[ -n "${SOURCE_URL}" ]]; then
  METADATA_ARGS+=(--label "org.opencontainers.image.source=${SOURCE_URL}")
fi

ATTESTATION_ARGS=()
if [[ "${DOCKER_PUSH:-}" == "1" || "${DOCKER_PLATFORM:-}" == *,* ]]; then
  ATTESTATION_ARGS=(--provenance=mode=max --sbom=true)
fi

exec docker buildx build \
  ${BUILDER_ARGS[@]+"${BUILDER_ARGS[@]}"} \
  ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} \
  -f deploy/docker/Dockerfile.ci \
  -t "openshell/ci:${IMAGE_TAG:-dev}" \
  ${METADATA_ARGS[@]+"${METADATA_ARGS[@]}"} \
  ${ATTESTATION_ARGS[@]+"${ATTESTATION_ARGS[@]}"} \
  "$@" \
  ${OUTPUT_ARGS[@]+"${OUTPUT_ARGS[@]}"} \
  .
