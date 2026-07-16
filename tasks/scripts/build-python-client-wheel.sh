#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT_DIR="${OPENSHELL_CLIENT_WHEEL_OUTPUT_DIR:-${ROOT}/target/wheels/client}"
VERSION="${OPENSHELL_CLIENT_WHEEL_VERSION:-}"

usage() {
  cat >&2 <<'EOF'
Usage: build-python-client-wheel.sh

Build a universal, pure-Python OpenShell gateway client wheel. This artifact
contains the SDK source and generated gRPC stubs only; it deliberately does not
contain the native OpenShell CLI binary.

Environment:
  OPENSHELL_CLIENT_WHEEL_OUTPUT_DIR  Destination directory for the wheel
  OPENSHELL_CLIENT_WHEEL_VERSION     PEP 440 version (defaults to Cargo workspace version)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 0 ]]; then
  usage
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(awk '
    /^\[workspace\.package\]$/ { in_workspace_package = 1; next }
    in_workspace_package && /^\[/ { exit }
    in_workspace_package && /^version[[:space:]]*=/ {
      gsub(/^[^\"]*\"|\".*$/, "")
      print
      exit
    }
  ' "${ROOT}/Cargo.toml")"
fi
if [[ -z "$VERSION" || ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*([A-Za-z0-9._-]*)?(\+[A-Za-z0-9._-]+)?$ ]]; then
  echo "OPENSHELL_CLIENT_WHEEL_VERSION must be a simple PEP 440 version: ${VERSION:-<empty>}" >&2
  exit 1
fi

SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD)"
SOURCE_REMOTE="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
case "$SOURCE_REMOTE" in
  git@github.com:*.git)
    SOURCE_URL="https://github.com/${SOURCE_REMOTE#git@github.com:}"
    SOURCE_URL="${SOURCE_URL%.git}"
    ;;
  ssh://git@github.com/*.git)
    SOURCE_URL="https://github.com/${SOURCE_REMOTE#ssh://git@github.com/}"
    SOURCE_URL="${SOURCE_URL%.git}"
    ;;
  https://github.com/*.git)
    SOURCE_URL="${SOURCE_REMOTE%.git}"
    ;;
  https://github.com/*)
    SOURCE_URL="$SOURCE_REMOTE"
    ;;
  *)
    SOURCE_URL="https://github.com/NVIDIA/OpenShell"
    ;;
esac

SOURCE_PACKAGE_DIR="${ROOT}/python/openshell"
if [[ ! -f "${SOURCE_PACKAGE_DIR}/__init__.py" || ! -f "${SOURCE_PACKAGE_DIR}/sandbox.py" ]]; then
  echo "OpenShell Python client source is incomplete: ${SOURCE_PACKAGE_DIR}" >&2
  exit 1
fi
if ! compgen -G "${SOURCE_PACKAGE_DIR}/_proto/*.py" >/dev/null; then
  echo "OpenShell generated Python protobuf stubs are missing; run mise run python:proto" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openshell-client-wheel.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
PACKAGE_DIR="${STAGE_DIR}/src/openshell"
mkdir -p "${PACKAGE_DIR}/_proto"

# Stage an explicit allowlist. The native CLI is packaged by maturin elsewhere.
install -m 0644 "${SOURCE_PACKAGE_DIR}/__init__.py" "${PACKAGE_DIR}/__init__.py"
install -m 0644 "${SOURCE_PACKAGE_DIR}/sandbox.py" "${PACKAGE_DIR}/sandbox.py"
for source_file in "${SOURCE_PACKAGE_DIR}/_proto/"*.py "${SOURCE_PACKAGE_DIR}/_proto/"*.pyi; do
  [[ -f "$source_file" ]] || continue
  install -m 0644 "$source_file" "${PACKAGE_DIR}/_proto/$(basename "$source_file")"
done

cat > "${STAGE_DIR}/pyproject.toml" <<EOF
[build-system]
requires = ["setuptools>=77"]
build-backend = "setuptools.build_meta"

[project]
name = "openshell"
version = "${VERSION}"
description = "OpenShell gateway client SDK"
license = "Apache-2.0"
readme = "README.md"
authors = [{ name = "NVIDIA Inc." }]
requires-python = ">=3.12"
dependencies = [
    "cloudpickle>=3.0",
    "grpcio>=1.60",
    "protobuf>=4.25",
]

[project.urls]
Source = "${SOURCE_URL}"
Source-Revision = "${SOURCE_URL}/commit/${SOURCE_REVISION}"

[tool.setuptools.packages.find]
where = ["src"]
include = ["openshell", "openshell.*"]

[tool.setuptools.package-data]
openshell = ["_proto/*.pyi"]
EOF

cat > "${STAGE_DIR}/README.md" <<'EOF'
# OpenShell Python Client

Pure-Python gateway client used by applications that control OpenShell through gRPC.
It intentionally excludes the native OpenShell CLI binary.
EOF

uv build --wheel --out-dir "$OUTPUT_DIR" "$STAGE_DIR"

WHEEL_PATH="${OUTPUT_DIR}/openshell-${VERSION}-py3-none-any.whl"
if [[ ! -f "$WHEEL_PATH" ]]; then
  echo "expected universal client wheel was not created: $WHEEL_PATH" >&2
  exit 1
fi

uv run --no-project python - "$WHEEL_PATH" "$SOURCE_PACKAGE_DIR" "$SOURCE_REVISION" "$SOURCE_URL" <<'PY'
import hashlib
import sys
import zipfile
from email.parser import BytesParser
from pathlib import Path

wheel_path = Path(sys.argv[1])
source_package_dir = Path(sys.argv[2])
source_revision = sys.argv[3]
source_url = sys.argv[4]

expected_files = {
    "openshell/__init__.py": source_package_dir / "__init__.py",
    "openshell/sandbox.py": source_package_dir / "sandbox.py",
}
for source_file in sorted((source_package_dir / "_proto").glob("*.py")):
    expected_files[f"openshell/_proto/{source_file.name}"] = source_file
for source_file in sorted((source_package_dir / "_proto").glob("*.pyi")):
    expected_files[f"openshell/_proto/{source_file.name}"] = source_file

with zipfile.ZipFile(wheel_path) as archive:
    members = {name for name in archive.namelist() if not name.endswith("/")}
    package_members = {name for name in members if name.startswith("openshell/")}
    unexpected_package_members = package_members - set(expected_files)
    missing_package_members = set(expected_files) - package_members
    if unexpected_package_members or missing_package_members:
        raise SystemExit(
            "client wheel package contents differ from allowlist: "
            f"unexpected={sorted(unexpected_package_members)}, "
            f"missing={sorted(missing_package_members)}"
        )

    disallowed_members = [
        name
        for name in members
        if ".data/scripts/" in name
        or name.endswith((".so", ".pyd", ".dll", ".dylib"))
        or "__pycache__/" in name
        or name.endswith("_test.py")
    ]
    if disallowed_members:
        raise SystemExit(
            f"client wheel contains disallowed native or test content: {sorted(disallowed_members)}"
        )

    for member, source_file in expected_files.items():
        source_hash = hashlib.sha256(source_file.read_bytes()).hexdigest()
        wheel_hash = hashlib.sha256(archive.read(member)).hexdigest()
        if source_hash != wheel_hash:
            raise SystemExit(f"client wheel source mismatch: {member}")

    metadata_members = sorted(
        name for name in members if name.endswith(".dist-info/METADATA")
    )
    wheel_members = sorted(name for name in members if name.endswith(".dist-info/WHEEL"))
    if len(metadata_members) != 1 or len(wheel_members) != 1:
        raise SystemExit("client wheel must contain exactly one dist-info metadata directory")
    metadata = BytesParser().parsebytes(archive.read(metadata_members[0]))
    if metadata["Name"] != "openshell":
        raise SystemExit(f"client wheel has unexpected project name: {metadata['Name']}")
    expected_project_url = f"Source-Revision, {source_url}/commit/{source_revision}"
    if expected_project_url not in metadata.get_all("Project-URL", []):
        raise SystemExit("client wheel source revision metadata does not match its source checkout")
    wheel_metadata = archive.read(wheel_members[0]).decode("utf-8")
    if "Root-Is-Purelib: true" not in wheel_metadata or "Tag: py3-none-any" not in wheel_metadata:
        raise SystemExit("client wheel is not universal pure Python")
PY

printf '%s\n' "$WHEEL_PATH"
