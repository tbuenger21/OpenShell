# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import json
from typing import TYPE_CHECKING, Any, cast

import pytest

from openshell._proto import openshell_pb2
from openshell.sandbox import (
    _PYTHON_CLOUDPICKLE_BOOTSTRAP,
    _SANDBOX_PYTHON_BIN,
    InferenceRouteClient,
    SandboxClient,
    SandboxError,
    SandboxRef,
    SandboxSession,
)

if TYPE_CHECKING:
    from pathlib import Path


class _FakeStub:
    def __init__(self) -> None:
        self.request: openshell_pb2.ExecSandboxRequest | None = None
        self.create_ssh_request: openshell_pb2.CreateSshSessionRequest | None = None
        self.revoke_ssh_request: openshell_pb2.RevokeSshSessionRequest | None = None
        self.ssh_session_response = openshell_pb2.CreateSshSessionResponse(
            sandbox_id="sandbox-1",
            token="session-token",
            gateway_host="gateway.example.test",
            gateway_port=443,
            gateway_scheme="https",
            connect_path="/connect/ssh",
            host_key_fingerprint="",
            expires_at_ms=1234,
        )

    def ExecSandbox(
        self,
        request: openshell_pb2.ExecSandboxRequest,
        timeout: float | None = None,
    ):
        self.request = request
        _ = timeout
        yield openshell_pb2.ExecSandboxEvent(
            exit=openshell_pb2.ExecSandboxExit(exit_code=0)
        )

    def CreateSshSession(
        self,
        request: openshell_pb2.CreateSshSessionRequest,
        timeout: float | None = None,
    ) -> openshell_pb2.CreateSshSessionResponse:
        self.create_ssh_request = request
        _ = timeout
        return self.ssh_session_response

    def RevokeSshSession(
        self,
        request: openshell_pb2.RevokeSshSessionRequest,
        timeout: float | None = None,
    ) -> openshell_pb2.RevokeSshSessionResponse:
        self.revoke_ssh_request = request
        _ = timeout
        return openshell_pb2.RevokeSshSessionResponse(revoked=True)


class _FakeInferenceStub:
    def __init__(self) -> None:
        self.request = None

    def SetClusterInference(self, request: Any, timeout: float | None = None) -> Any:
        self.request = request
        _ = timeout

        class _Response:
            provider_name = request.provider_name
            model_id = request.model_id
            version = 1

        return _Response()


def _client_with_fake_stub(stub: _FakeStub) -> SandboxClient:
    client = cast("SandboxClient", object.__new__(SandboxClient))
    client._timeout = 30.0
    client._stub = cast("Any", stub)
    return client


def test_exec_sends_stdin_payload() -> None:
    stub = _FakeStub()
    client = _client_with_fake_stub(stub)

    result = client.exec("sandbox-1", ["python", "-c", "print('ok')"], stdin=b"payload")

    assert result.exit_code == 0
    assert stub.request is not None
    assert stub.request.stdin == b"payload"


def test_create_ssh_session_returns_validated_tunnel_credentials() -> None:
    stub = _FakeStub()
    client = _client_with_fake_stub(stub)

    session = client.create_ssh_session("sandbox-1")

    assert stub.create_ssh_request is not None
    assert stub.create_ssh_request.sandbox_id == "sandbox-1"
    assert session.sandbox_id == "sandbox-1"
    assert session.token == "session-token"
    assert session.gateway_host == "gateway.example.test"
    assert session.gateway_port == 443
    assert session.gateway_scheme == "https"
    assert session.connect_path == "/connect/ssh"
    assert session.expires_at_ms == 1234
    assert "session-token" not in repr(session)


def test_create_ssh_session_rejects_a_different_sandbox_response() -> None:
    stub = _FakeStub()
    stub.ssh_session_response.sandbox_id = "other-sandbox"
    client = _client_with_fake_stub(stub)

    with pytest.raises(SandboxError, match="different sandbox"):
        client.create_ssh_session("sandbox-1")


@pytest.mark.parametrize(
    ("field", "value", "error"),
    [
        ("gateway_port", 0, "invalid gateway port"),
        ("gateway_port", 65536, "invalid gateway port"),
        ("gateway_scheme", "ssh", "invalid gateway scheme"),
        ("connect_path", "connect/ssh", "invalid connect path"),
        (
            "host_key_fingerprint",
            "SHA256:invalid fingerprint",
            "invalid host key fingerprint",
        ),
        ("expires_at_ms", -1, "invalid expiry timestamp"),
    ],
)
def test_create_ssh_session_rejects_invalid_tunnel_response(
    field: str,
    value: object,
    error: str,
) -> None:
    stub = _FakeStub()
    setattr(stub.ssh_session_response, field, value)
    client = _client_with_fake_stub(stub)

    with pytest.raises(SandboxError, match=error):
        client.create_ssh_session("sandbox-1")


def test_sandbox_session_creates_ssh_credentials_for_its_id() -> None:
    stub = _FakeStub()
    client = _client_with_fake_stub(stub)
    sandbox = SandboxSession(
        client,
        SandboxRef(
            id="sandbox-1",
            name="sandbox-name",
            namespace="default",
            phase=1,
        ),
    )

    session = sandbox.create_ssh_session()

    assert session.sandbox_id == "sandbox-1"
    assert stub.create_ssh_request is not None
    assert stub.create_ssh_request.sandbox_id == "sandbox-1"


def test_revoke_ssh_session_forwards_the_tunnel_token() -> None:
    stub = _FakeStub()
    client = _client_with_fake_stub(stub)

    assert client.revoke_ssh_session("session-token") is True
    assert stub.revoke_ssh_request is not None
    assert stub.revoke_ssh_request.token == "session-token"


def test_revoke_ssh_session_rejects_invalid_token() -> None:
    stub = _FakeStub()
    client = _client_with_fake_stub(stub)

    with pytest.raises(SandboxError, match="invalid charset"):
        client.revoke_ssh_session("token with spaces")

    assert stub.revoke_ssh_request is None


def test_exec_python_serializes_callable_payload() -> None:
    stub = _FakeStub()
    client = _client_with_fake_stub(stub)

    def add(a: int, b: int) -> int:
        return a + b

    result = client.exec_python("sandbox-1", add, args=(2, 3))

    assert result.exit_code == 0
    assert stub.request is not None
    assert stub.request.command == [
        _SANDBOX_PYTHON_BIN,
        "-c",
        _PYTHON_CLOUDPICKLE_BOOTSTRAP,
    ]
    assert stub.request.environment["OPENSHELL_PYFUNC_B64"]
    assert stub.request.stdin == b""


def test_from_active_cluster_reads_gateway_metadata_layout(
    tmp_path: Path,
    monkeypatch: Any,
) -> None:
    gateway_name = "test-gateway"
    gateway_dir = tmp_path / "openshell" / "gateways" / gateway_name
    mtls_dir = gateway_dir / "mtls"
    mtls_dir.mkdir(parents=True)
    (tmp_path / "openshell" / "active_gateway").write_text(gateway_name)
    (gateway_dir / "metadata.json").write_text(
        json.dumps({"gateway_endpoint": "https://127.0.0.1:8443"})
    )
    (mtls_dir / "ca.crt").write_text("ca")
    (mtls_dir / "tls.crt").write_text("cert")
    (mtls_dir / "tls.key").write_text("key")

    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    monkeypatch.delenv("OPENSHELL_GATEWAY", raising=False)

    client = SandboxClient.from_active_cluster()
    try:
        assert client._cluster_name == gateway_name
    finally:
        client.close()


def test_from_active_cluster_prefers_openshell_gateway_env(
    tmp_path: Path,
    monkeypatch: Any,
) -> None:
    gateway_name = "env-gateway"
    gateway_dir = tmp_path / "openshell" / "gateways" / gateway_name
    mtls_dir = gateway_dir / "mtls"
    mtls_dir.mkdir(parents=True)
    (gateway_dir / "metadata.json").write_text(
        json.dumps({"gateway_endpoint": "https://127.0.0.1:8443"})
    )
    (mtls_dir / "ca.crt").write_text("ca")
    (mtls_dir / "tls.crt").write_text("cert")
    (mtls_dir / "tls.key").write_text("key")

    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    monkeypatch.setenv("OPENSHELL_GATEWAY", gateway_name)

    client = SandboxClient.from_active_cluster()
    try:
        assert client._cluster_name == gateway_name
    finally:
        client.close()


def test_inference_set_cluster_forwards_no_verify_flag() -> None:
    stub = _FakeInferenceStub()
    client = cast("InferenceRouteClient", object.__new__(InferenceRouteClient))
    client._timeout = 30.0
    client._stub = cast("Any", stub)

    client.set_cluster(
        provider_name="openai-dev",
        model_id="gpt-4.1",
        no_verify=True,
    )

    assert stub.request is not None
    assert stub.request.no_verify is True
