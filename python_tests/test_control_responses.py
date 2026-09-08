"""Shared synthetic response contract; no network or application host."""
import json
from pathlib import Path

import pytest
from openquii.client import InvalidResponseError, _parse_protocol_code

CASES = json.loads(
    (Path(__file__).resolve().parents[1] / "protocol/control_responses.json").read_text()
)["cases"]


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["id"])
def test_shared_control_response_contract(case):
    if case["code"] is None:
        with pytest.raises(InvalidResponseError):
            _parse_protocol_code(case["xml"])
    else:
        assert _parse_protocol_code(case["xml"]) == case["code"]
