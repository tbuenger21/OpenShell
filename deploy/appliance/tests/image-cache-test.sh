#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT}/deploy/appliance/image-cache.sh"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

FAKE_BIN="$TMP_DIR/bin"
BUNDLE_DIR="$TMP_DIR/bundle"
STORE_FILE="$TMP_DIR/images.txt"
IMPORT_LOG="$TMP_DIR/imports.txt"

mkdir -p "$FAKE_BIN" "$BUNDLE_DIR/images"
touch "$STORE_FILE" "$IMPORT_LOG"

cat >"$FAKE_BIN/k3s" <<EOF
#!/usr/bin/env bash
set -euo pipefail

STORE_FILE="$STORE_FILE"
IMPORT_LOG="$IMPORT_LOG"

if [[ "\$1" != "ctr" || "\$2" != "-n" || "\$3" != "k8s.io" ]]; then
  echo "unexpected k3s invocation: \$*" >&2
  exit 2
fi
shift 3

case "\$*" in
  "images ls -q name=="*)
    image="\${*: -1}"
    image="\${image#name==}"
    grep -Fx "\$image" "\$STORE_FILE" || true
    ;;
  "images import "*)
    archive="\${*: -1}"
    basename="\$(basename "\$archive")"
    case "\$basename" in
      gateway.oci.tar)
        image="example.local/openshell/gateway:2026-07-09"
        ;;
      sandbox.oci.tar)
        image="example.local/potatostew/sandbox:2026-07-09"
        ;;
      supervisor.oci.tar)
        image="example.local/openshell/supervisor:2026-07-09"
        ;;
      agent-sandbox-controller.oci.tar)
        image="example.local/agent-sandbox-controller:v0.1.0"
        ;;
      *)
        echo "unknown archive: \$archive" >&2
        exit 3
        ;;
    esac
    echo "\$archive" >>"\$IMPORT_LOG"
    grep -Fx "\$image" "\$STORE_FILE" >/dev/null 2>&1 || echo "\$image" >>"\$STORE_FILE"
    ;;
  *)
    echo "unexpected ctr invocation: \$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$FAKE_BIN/k3s"

cat >"$FAKE_BIN/ctr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$FAKE_BIN/k3s" ctr "\$@"
EOF
chmod +x "$FAKE_BIN/ctr"

cat >"$BUNDLE_DIR/manifest.env" <<'EOF'
OPENSHELL_BUNDLE_GATEWAY_IMAGE='example.local/openshell/gateway:2026-07-09'
OPENSHELL_BUNDLE_SANDBOX_IMAGE='example.local/potatostew/sandbox:2026-07-09'
OPENSHELL_BUNDLE_SUPERVISOR_IMAGE='example.local/openshell/supervisor:2026-07-09'
OPENSHELL_BUNDLE_AGENT_SANDBOX_CONTROLLER_IMAGE='example.local/agent-sandbox-controller:v0.1.0'
EOF

touch \
  "$BUNDLE_DIR/images/gateway.oci.tar" \
  "$BUNDLE_DIR/images/sandbox.oci.tar" \
  "$BUNDLE_DIR/images/supervisor.oci.tar" \
  "$BUNDLE_DIR/images/agent-sandbox-controller.oci.tar"

run_cache() {
  PATH="$FAKE_BIN:$PATH" \
  OPENSHELL_IMAGE_BUNDLE="$BUNDLE_DIR" \
  OPENSHELL_IMAGE_CACHE_DISK_MIN_FREE_PERCENT=0 \
  OPENSHELL_IMAGE_CACHE_COMPLETE_FILE="$TMP_DIR/complete" \
  OPENSHELL_IMAGE_CACHE_STATE_FILE="$TMP_DIR/image-cache.env" \
  OPENSHELL_IMAGE_CACHE_LOCK_DIR="$TMP_DIR/lock" \
  "$SCRIPT" "$@"
}

assert_import_count() {
  expected="$1"
  actual="$(wc -l <"$IMPORT_LOG" | tr -d ' ')"
  if [[ "$actual" != "$expected" ]]; then
    echo "expected $expected imports, got $actual" >&2
    cat "$IMPORT_LOG" >&2
    exit 1
  fi
}

if run_cache check >/dev/null 2>&1; then
  echo "check unexpectedly passed before images were imported" >&2
  exit 1
fi
assert_import_count 0

run_cache ensure
assert_import_count 4

run_cache check
assert_import_count 4

run_cache ensure
assert_import_count 4

echo "image-cache-test: ok"
