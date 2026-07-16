#!/bin/sh

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -eu

KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
OPENSHELL_NAMESPACE="${OPENSHELL_BOOTSTRAP_NAMESPACE:-openshell}"
IMAGE_CACHE_SCRIPT="${OPENSHELL_IMAGE_CACHE_SCRIPT:-/usr/local/bin/openshell-image-cache.sh}"
REQUIRE_IMAGE_CACHE="${OPENSHELL_IMAGE_CACHE_REQUIRED:-1}"
GATEWAY_PROBE_URL="${OPENSHELL_GATEWAY_PROBE_URL:-http://127.0.0.1:${OPENSHELL_GATEWAY_FORWARD_PORT:-30051}/}"
GATEWAY_PROBE_TIMEOUT_S="${OPENSHELL_GATEWAY_PROBE_TIMEOUT_S:-2}"

log() {
    printf '%s\n' "openshell-appliance-healthcheck: $*" >&2
}

gateway_port_is_reachable() {
    probe_output="$(
        wget -S -T "$GATEWAY_PROBE_TIMEOUT_S" -O /dev/null "$GATEWAY_PROBE_URL" 2>&1
    )" && return 0

    printf '%s\n' "$probe_output" | grep -E 'HTTP/[0-9.]+[[:space:]]+[0-9]+' >/dev/null 2>&1
}

if [ ! -f "$KUBECONFIG_PATH" ]; then
    log "kubeconfig is missing"
    exit 1
fi

if ! KUBECONFIG="$KUBECONFIG_PATH" kubectl get --raw=/readyz >/dev/null 2>&1; then
    log "k3s is not ready"
    exit 1
fi

if [ "$REQUIRE_IMAGE_CACHE" = "1" ]; then
    if [ ! -x "$IMAGE_CACHE_SCRIPT" ]; then
        log "image-cache script is missing or not executable: $IMAGE_CACHE_SCRIPT"
        exit 1
    fi
    if ! "$IMAGE_CACHE_SCRIPT" check; then
        log "required images are missing from k3s image cache"
        exit 1
    fi
fi

if [ ! -x /opt/openshell/bin/openshell-sandbox ]; then
    log "sandbox supervisor binary is missing: /opt/openshell/bin/openshell-sandbox"
    exit 1
fi

ready="$(
    KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$OPENSHELL_NAMESPACE" \
        get statefulset openshell \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true
)"

if [ "$ready" != "1" ]; then
    log "OpenShell gateway is not ready"
    exit 1
fi

if ! gateway_port_is_reachable; then
    log "OpenShell gateway port is not reachable: $GATEWAY_PROBE_URL"
    exit 1
fi
