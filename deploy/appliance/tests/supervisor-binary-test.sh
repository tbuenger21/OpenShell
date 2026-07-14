#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DOCKERFILE="${ROOT}/deploy/docker/Dockerfile.appliance"
HEALTHCHECK="${ROOT}/deploy/appliance/healthcheck.sh"

grep -Fq 'ARG OPENSHELL_APPLIANCE_SUPERVISOR_IMAGE' "$DOCKERFILE"
grep -Fq 'FROM ${OPENSHELL_APPLIANCE_SUPERVISOR_IMAGE} AS openshell-supervisor' "$DOCKERFILE"
grep -Fq 'COPY --from=openshell-supervisor /usr/local/bin/openshell-sandbox /opt/openshell/bin/openshell-sandbox' "$DOCKERFILE"
grep -Fq '/opt/openshell/bin/openshell-sandbox' "$HEALTHCHECK"

echo "supervisor-binary-test: ok"
