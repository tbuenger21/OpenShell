# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Regression coverage for the standalone pure-Python client wheel."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD_SCRIPT = ROOT / "tasks" / "scripts" / "build-python-client-wheel.sh"


def test_client_wheel_imports_without_native_cli() -> None:
    """The application client wheel must remain portable and CLI-free."""
    with tempfile.TemporaryDirectory() as temp_dir:
        output_dir = Path(temp_dir) / "wheel"
        environment = os.environ | {
            "OPENSHELL_CLIENT_WHEEL_OUTPUT_DIR": str(output_dir),
            "OPENSHELL_CLIENT_WHEEL_VERSION": "0.0.0+clienttest",
        }
        build_result = subprocess.run(
            [str(BUILD_SCRIPT)],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            check=False,
            text=True,
        )
        assert build_result.returncode == 0, build_result.stderr

        wheel_path = output_dir / "openshell-0.0.0+clienttest-py3-none-any.whl"
        assert wheel_path.is_file()

        import_environment = os.environ.copy()
        import_environment.pop("PYTHONPATH", None)
        import_result = subprocess.run(
            [
                sys.executable,
                "-c",
                "\n".join(
                    [
                        "import sys",
                        f"sys.path.insert(0, {str(wheel_path)!r})",
                        "import openshell.sandbox as sandbox",
                        "import openshell._proto.openshell_pb2 as openshell_pb2",
                        "assert sandbox.SandboxClient",
                        "assert sandbox.SshSession",
                        "assert openshell_pb2.Sandbox",
                    ]
                ),
            ],
            cwd=Path(temp_dir),
            env=import_environment,
            capture_output=True,
            check=False,
            text=True,
        )
        assert import_result.returncode == 0, import_result.stderr
