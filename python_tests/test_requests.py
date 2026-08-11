"""Request construction and explicit credential-separation tests."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from openquii import (
    ControlCredentials,
    ControlUsername,
    CredentialValidationError,
    Door,
    UnlockPassword,
    UnlockPasswordDigest,
    VerificationDigest,
    build_open_door_request,
    build_status_request,
)

_REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


def _fixtures() -> dict[str, Any]:
    return json.loads((_REPOSITORY_ROOT / "protocol" / "control_requests.json").read_text())


def _credentials(fixture: dict[str, Any]) -> ControlCredentials:
    return ControlCredentials(
        username=ControlUsername(fixture["username"]),
        verification_digest=VerificationDigest(fixture["verification_digest"]),
    )


def test_shared_status_request_contract() -> None:
    fixture = _fixtures()
    request = build_status_request("192.168.50.10", _credentials(fixture))

    assert request.method == fixture["method"]
    assert request.url == f"http://192.168.50.10{fixture['path']}"
    assert request.headers["Content-Type"] == fixture["content_type"]
    assert request.body == fixture["status"]["expected_xml"]
    assert "opendoor" not in request.body
    assert "<door>" not in request.body


@pytest.mark.parametrize("control", _fixtures()["controls"], ids=lambda item: item["id"])
def test_shared_control_request_contract(control: dict[str, Any]) -> None:
    fixture = _fixtures()
    raw_credential = control["unlock_credential"]
    unlock = (
        UnlockPasswordDigest(raw_credential["value"])
        if raw_credential["kind"] == "sha256_digest"
        else UnlockPassword(raw_credential["value"])
    )
    request = build_open_door_request(
        "192.168.50.10",
        _credentials(fixture),
        unlock,
        Door(control["door"]),
    )

    assert control["lock"] == 1
    assert request.body == control["expected_xml"]
    assert request.body.count(f"<password>{fixture['verification_digest']}</password>") == 1
    assert request.body.count(f"<password>{unlock.sha256_digest}</password>") == 1


def test_credentials_are_explicit_and_redacted_from_representations() -> None:
    username = ControlUsername("fake-user")
    verification = VerificationDigest("A" * 64)
    password = UnlockPassword("fake-secret")
    digest = UnlockPasswordDigest("B" * 64)
    credentials = ControlCredentials(username, verification)

    assert verification.value == "a" * 64
    assert digest.value == "b" * 64
    assert "fake-user" not in repr(username)
    assert "fake-secret" not in repr(password)
    assert verification.value not in repr(verification)
    assert digest.value not in repr(digest)
    assert "fake-user" not in repr(credentials)


@pytest.mark.parametrize(
    "constructor,value",
    [
        (ControlUsername, ""),
        (VerificationDigest, "not-a-digest"),
        (UnlockPassword, "   "),
        (UnlockPasswordDigest, "not-a-digest"),
    ],
)
def test_invalid_credentials_are_rejected(constructor: Any, value: str) -> None:
    with pytest.raises(CredentialValidationError):
        constructor(value)


def test_only_enum_door_values_are_accepted() -> None:
    fixture = _fixtures()
    with pytest.raises(TypeError):
        build_open_door_request(
            "192.168.50.10",
            _credentials(fixture),
            UnlockPassword("fake-secret"),
            1,  # type: ignore[arg-type]
        )
    with pytest.raises(ValueError):
        Door(3)
