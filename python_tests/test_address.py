"""Address contract tests loaded from the language-neutral fixtures."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from openquii import AddressValidationError, canonicalize_monitor_address

_REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


def _address_cases() -> list[dict[str, Any]]:
    fixture = json.loads((_REPOSITORY_ROOT / "protocol" / "addresses.json").read_text())
    return list(fixture["cases"])


@pytest.mark.parametrize("fixture", _address_cases(), ids=lambda fixture: fixture["id"])
def test_shared_address_contract(fixture: dict[str, Any]) -> None:
    expected = fixture["canonical"]
    if expected is None:
        with pytest.raises(AddressValidationError):
            canonicalize_monitor_address(fixture["input"])
        return

    address = canonicalize_monitor_address(fixture["input"])
    assert address.base_url == expected
    assert address.control_url == f"{expected}/tdkcgi"
