#!/bin/sh

set -eu

K3S_BIN="${K3S_BIN:-/bin/k3s}"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
ASSET_DIR="${OPENSHELL_APPLIANCE_ASSET_DIR:-/opt/openshell/assets}"
OPENSHELL_NAMESPACE_DEFAULT="openshell"
OPENSHELL_NAMESPACE="${OPENSHELL_BOOTSTRAP_NAMESPACE:-$OPENSHELL_NAMESPACE_DEFAULT}"
OPENSHELL_CHART_NAME_DEFAULT="openshell-0.1.0.tgz"
OPENSHELL_CHART_ARCHIVE="${OPENSHELL_CHART_ARCHIVE:-$ASSET_DIR/$OPENSHELL_CHART_NAME_DEFAULT}"
AGENT_SANDBOX_MANIFEST="${OPENSHELL_AGENT_SANDBOX_MANIFEST:-$ASSET_DIR/agent-sandbox.yaml}"
IMAGE_CACHE_SCRIPT="${OPENSHELL_IMAGE_CACHE_SCRIPT:-/usr/local/bin/openshell-image-cache.sh}"
BOOT_TIMEOUT_S="${OPENSHELL_BOOT_TIMEOUT_S:-600}"
GATEWAY_FORWARD_HOST="${OPENSHELL_GATEWAY_FORWARD_HOST:-0.0.0.0}"
GATEWAY_FORWARD_PORT="${OPENSHELL_GATEWAY_FORWARD_PORT:-30051}"
GATEWAY_SERVICE_PORT="${OPENSHELL_GATEWAY_SERVICE_PORT:-8080}"
IMAGE_CACHE_REQUIRED="${OPENSHELL_IMAGE_CACHE_REQUIRED:-1}"
IMAGE_CACHE_REQUIRE_NEVER="${OPENSHELL_IMAGE_CACHE_REQUIRE_PULL_POLICY_NEVER:-1}"
IMAGE_CACHE_RECONCILE_INTERVAL_S="${OPENSHELL_IMAGE_CACHE_RECONCILE_INTERVAL_S:-300}"

GATEWAY_IMAGE=""
SANDBOX_IMAGE=""
SUPERVISOR_IMAGE=""
AGENT_SANDBOX_CONTROLLER_IMAGE=""

GATEWAY_IMAGE_PULL_POLICY="${OPENSHELL_GATEWAY_IMAGE_PULL_POLICY:-Never}"
SANDBOX_IMAGE_PULL_POLICY="${OPENSHELL_SANDBOX_IMAGE_PULL_POLICY:-Never}"
SUPERVISOR_IMAGE_PULL_POLICY="${OPENSHELL_SUPERVISOR_IMAGE_PULL_POLICY:-Never}"
AGENT_SANDBOX_CONTROLLER_IMAGE_PULL_POLICY="${OPENSHELL_AGENT_SANDBOX_CONTROLLER_IMAGE_PULL_POLICY:-Never}"

log() {
    printf '%s\n' "openshell-appliance: $*" >&2
}

die() {
    log "$*"
    exit 1
}

verify_positive_integer() {
    value="$1"
    name="$2"

    case "$value" in
        ''|*[!0-9]*)
            die "$name must be a positive integer"
            ;;
    esac
    if [ "$value" -eq 0 ]; then
        die "$name must be greater than zero"
    fi
}

verify_nonnegative_integer() {
    value="$1"
    name="$2"

    case "$value" in
        ''|*[!0-9]*)
            die "$name must be a non-negative integer"
            ;;
    esac
}

verify_policy_never() {
    value="$1"
    name="$2"

    if [ "$IMAGE_CACHE_REQUIRE_NEVER" = "1" ] && [ "$value" != "Never" ]; then
        die "$name must be Never when OPENSHELL_IMAGE_CACHE_REQUIRE_PULL_POLICY_NEVER=1"
    fi
}

image_repo() {
    image="$1"

    case "$image" in
        *@*)
            die "digest image refs are not supported by the Helm chart renderer yet: $image"
            ;;
        *:*)
            printf '%s\n' "${image%:*}"
            ;;
        *)
            die "image ref must include an explicit tag: $image"
            ;;
    esac
}

image_tag() {
    image="$1"

    case "$image" in
        *@*)
            die "digest image refs are not supported by the Helm chart renderer yet: $image"
            ;;
        *:*)
            printf '%s\n' "${image##*:}"
            ;;
        *)
            die "image ref must include an explicit tag: $image"
            ;;
    esac
}

load_bundle_manifest() {
    [ -x "$IMAGE_CACHE_SCRIPT" ] || die "OpenShell image-cache script is not executable: $IMAGE_CACHE_SCRIPT"
    eval "$("$IMAGE_CACHE_SCRIPT" manifest-env)"

    export OPENSHELL_IMAGE_CACHE_REQUIRED_IMAGES="$OPENSHELL_IMAGE_CACHE_REQUIRED_IMAGES_EFFECTIVE"

    log "using OpenShell image refs from image bundle"
    log "gateway image: $GATEWAY_IMAGE"
    log "sandbox image: $SANDBOX_IMAGE"
    log "supervisor image: $SUPERVISOR_IMAGE"
    log "agent-sandbox controller image: $AGENT_SANDBOX_CONTROLLER_IMAGE"
}

wait_for_kubernetes() {
    deadline=$(( $(date +%s) + BOOT_TIMEOUT_S ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -f "$KUBECONFIG_PATH" ] \
            && KUBECONFIG="$KUBECONFIG_PATH" kubectl get --raw=/readyz >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    return 1
}

apply_agent_sandbox_manifest() {
    rendered="/tmp/openshell-agent-sandbox.yaml"

    [ -f "$AGENT_SANDBOX_MANIFEST" ] || die "agent-sandbox manifest not found: $AGENT_SANDBOX_MANIFEST"

    awk \
        -v image="$AGENT_SANDBOX_CONTROLLER_IMAGE" \
        -v pull_policy="$AGENT_SANDBOX_CONTROLLER_IMAGE_PULL_POLICY" '
        /^[[:space:]]*image:[[:space:]]*registry\.k8s\.io\/agent-sandbox\/agent-sandbox-controller:/ {
            indent = substr($0, 1, index($0, "image:") - 1)
            print indent "image: " image
            print indent "imagePullPolicy: " pull_policy
            next
        }
        { print }
    ' "$AGENT_SANDBOX_MANIFEST" >"$rendered"

    log "applying OpenShell agent-sandbox CRD/controller manifest"
    KUBECONFIG="$KUBECONFIG_PATH" kubectl apply -f "$rendered" >/dev/null
}

write_helmchart_manifest() {
    manifest="/tmp/openshell-helmchart.yaml"
    chart_dir="/var/lib/rancher/k3s/server/static/charts"
    chart_name="$(basename "$OPENSHELL_CHART_ARCHIVE")"
    gateway_repo="$(image_repo "$GATEWAY_IMAGE")"
    gateway_tag="$(image_tag "$GATEWAY_IMAGE")"
    supervisor_repo="$(image_repo "$SUPERVISOR_IMAGE")"
    supervisor_tag="$(image_tag "$SUPERVISOR_IMAGE")"
    disable_tls="${DISABLE_TLS:-${OPENSHELL_DISABLE_TLS:-true}}"
    host_gateway_ip="${OPENSHELL_HOST_GATEWAY_IP:-172.17.0.1}"

    [ -f "$OPENSHELL_CHART_ARCHIVE" ] || die "OpenShell Helm chart archive not found: $OPENSHELL_CHART_ARCHIVE"

    mkdir -p "$chart_dir"
    cp "$OPENSHELL_CHART_ARCHIVE" "$chart_dir/$chart_name"

    cat >"$manifest" <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: openshell
  namespace: kube-system
spec:
  chart: https://%{KUBERNETES_API}%/static/charts/$chart_name
  targetNamespace: $OPENSHELL_NAMESPACE
  createNamespace: true
  valuesContent: |-
    image:
      repository: $gateway_repo
      tag: $gateway_tag
      pullPolicy: $GATEWAY_IMAGE_PULL_POLICY
    supervisor:
      image:
        repository: $supervisor_repo
        tag: $supervisor_tag
        pullPolicy: $SUPERVISOR_IMAGE_PULL_POLICY
      sideloadMethod: init-container
    server:
      sandboxNamespace: $OPENSHELL_NAMESPACE
      sandboxImage: $SANDBOX_IMAGE
      sandboxImagePullPolicy: $SANDBOX_IMAGE_PULL_POLICY
      dbUrl: sqlite:/var/openshell/openshell.db
      hostGatewayIP: "$host_gateway_ip"
      disableTls: $disable_tls
      tls:
        certSecretName: openshell-server-tls
        clientCaSecretName: openshell-server-client-ca
        clientTlsSecretName: openshell-client-tls
    service:
      port: 8080
      healthPort: 8081
      metricsPort: 9090
EOF

    log "installing OpenShell Helm chart"
    KUBECONFIG="$KUBECONFIG_PATH" kubectl apply -f "$manifest" >/dev/null
}

wait_for_gateway() {
    deadline=$(( $(date +%s) + BOOT_TIMEOUT_S ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        ready="$(
            KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$OPENSHELL_NAMESPACE" \
                get statefulset openshell \
                -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true
        )"
        if [ "$ready" = "1" ]; then
            return 0
        fi
        sleep 2
    done

    return 1
}

shutdown_k3s() {
    if [ "${IMAGE_CACHE_RECONCILE_PID:-}" ]; then
        kill "$IMAGE_CACHE_RECONCILE_PID" >/dev/null 2>&1 || true
        wait "$IMAGE_CACHE_RECONCILE_PID" >/dev/null 2>&1 || true
    fi
    if [ "${GATEWAY_FORWARD_PID:-}" ]; then
        kill "$GATEWAY_FORWARD_PID" >/dev/null 2>&1 || true
        wait "$GATEWAY_FORWARD_PID" >/dev/null 2>&1 || true
    fi
    if [ "${K3S_PID:-}" ]; then
        kill "$K3S_PID" >/dev/null 2>&1 || true
        wait "$K3S_PID" >/dev/null 2>&1 || true
    fi
}

start_gateway_port_forward() {
    log "forwarding OpenShell gateway on ${GATEWAY_FORWARD_HOST}:${GATEWAY_FORWARD_PORT} -> service/openshell:${GATEWAY_SERVICE_PORT}"
    KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$OPENSHELL_NAMESPACE" \
        port-forward \
        --address "$GATEWAY_FORWARD_HOST" \
        service/openshell \
        "${GATEWAY_FORWARD_PORT}:${GATEWAY_SERVICE_PORT}" \
        >/tmp/openshell-port-forward.log 2>&1 &
    GATEWAY_FORWARD_PID="$!"
}

start_image_cache_reconcile() {
    verify_nonnegative_integer "$IMAGE_CACHE_RECONCILE_INTERVAL_S" OPENSHELL_IMAGE_CACHE_RECONCILE_INTERVAL_S
    if [ "$IMAGE_CACHE_RECONCILE_INTERVAL_S" -eq 0 ]; then
        log "image-cache reconcile loop disabled"
        return 0
    fi

    "$IMAGE_CACHE_SCRIPT" reconcile &
    IMAGE_CACHE_RECONCILE_PID="$!"
    log "started image-cache reconcile loop with pid $IMAGE_CACHE_RECONCILE_PID"
}

verify_positive_integer "$BOOT_TIMEOUT_S" OPENSHELL_BOOT_TIMEOUT_S
verify_positive_integer "$GATEWAY_FORWARD_PORT" OPENSHELL_GATEWAY_FORWARD_PORT
verify_positive_integer "$GATEWAY_SERVICE_PORT" OPENSHELL_GATEWAY_SERVICE_PORT
verify_nonnegative_integer "$IMAGE_CACHE_RECONCILE_INTERVAL_S" OPENSHELL_IMAGE_CACHE_RECONCILE_INTERVAL_S
load_bundle_manifest
verify_policy_never "$GATEWAY_IMAGE_PULL_POLICY" OPENSHELL_GATEWAY_IMAGE_PULL_POLICY
verify_policy_never "$SANDBOX_IMAGE_PULL_POLICY" OPENSHELL_SANDBOX_IMAGE_PULL_POLICY
verify_policy_never "$SUPERVISOR_IMAGE_PULL_POLICY" OPENSHELL_SUPERVISOR_IMAGE_PULL_POLICY
verify_policy_never "$AGENT_SANDBOX_CONTROLLER_IMAGE_PULL_POLICY" OPENSHELL_AGENT_SANDBOX_CONTROLLER_IMAGE_PULL_POLICY

if [ "$#" -eq 0 ]; then
    set -- server --disable=traefik --tls-san=127.0.0.1 --tls-san=localhost --tls-san=host.docker.internal
fi

log "starting k3s: $*"
"$K3S_BIN" "$@" &
K3S_PID="$!"
trap shutdown_k3s INT TERM

if ! wait_for_kubernetes; then
    shutdown_k3s
    die "timed out waiting for k3s readiness"
fi

log "k3s is ready"

if [ "$IMAGE_CACHE_REQUIRED" = "1" ]; then
    "$IMAGE_CACHE_SCRIPT" ensure
    start_image_cache_reconcile
else
    log "image-cache requirement disabled"
fi

apply_agent_sandbox_manifest
write_helmchart_manifest

if ! wait_for_gateway; then
    log "timed out waiting for OpenShell gateway readiness; container stays up for inspection"
else
    log "OpenShell gateway is ready"
    start_gateway_port_forward
fi

wait "$K3S_PID"

