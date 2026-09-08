"""One-shot executor tests with a network-free aiohttp-like fake."""

from __future__ import annotations

import asyncio
import json
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn

import pytest
from openquii import (
    ControlCredentials,
    ControlRejectedError,
    ControlUsername,
    Door,
    InvalidResponseError,
    OpenQUIIClient,
    RedirectRejectedError,
    TransportError,
    UnlockPassword,
    VerificationDigest,
)

_SUCCESS = '<?xml version="1.0"?><envelope><body><result>0</result></body></envelope>'


@dataclass
class FakeResponse:
    status: int
    body: str
    released: bool = False

    async def text(self) -> str:
        return self.body

    def release(self) -> None:
        self.released = True


class FakeSession:
    def __init__(self, response: FakeResponse) -> None:
        self.response = response
        self.calls: list[dict[str, object]] = []
        self.close_calls = 0

    async def request(
        self,
        method: str,
        url: str,
        *,
        data: bytes,
        headers: Mapping[str, str],
        allow_redirects: bool,
        timeout: float,
    ) -> FakeResponse:
        self.calls.append(
            {
                "method": method,
                "url": url,
                "data": data,
                "headers": dict(headers),
                "allow_redirects": allow_redirects,
                "timeout": timeout,
            }
        )
        return self.response

    async def close(self) -> None:
        self.close_calls += 1


class FailingResponse(FakeResponse):
    async def text(self) -> NoReturn:
        raise OSError("synthetic response-body private detail")


class FailingSession(FakeSession):
    async def request(
        self,
        method: str,
        url: str,
        *,
        data: bytes,
        headers: Mapping[str, str],
        allow_redirects: bool,
        timeout: float,
    ) -> NoReturn:
        self.calls.append({"method": method, "url": url})
        raise OSError("synthetic transport failure")


def _client(session: FakeSession) -> OpenQUIIClient:
    return OpenQUIIClient(
        session,
        "192.168.50.10",
        ControlCredentials(ControlUsername("fake-user"), VerificationDigest("a" * 64)),
    )


def test_accepted_press_executes_exactly_one_non_redirecting_request() -> None:
    response = FakeResponse(200, _SUCCESS)
    session = FakeSession(response)

    asyncio.run(_client(session).open_door(Door.ONE, UnlockPassword("fake-secret")))

    assert len(session.calls) == 1
    assert session.calls[0]["allow_redirects"] is False
    assert b"<door>1</door><locknumber>1</locknumber>" in session.calls[0]["data"]
    assert response.released
    assert session.close_calls == 0


def test_status_is_authenticated_read_only_and_does_not_close_session() -> None:
    session = FakeSession(FakeResponse(200, _SUCCESS))

    status = asyncio.run(_client(session).read_status())

    assert status.protocol_code == "0"
    assert len(session.calls) == 1
    body = session.calls[0]["data"]
    assert isinstance(body, bytes)
    assert b"get.device.status" in body
    assert b"opendoor" not in body
    assert b"<door>" not in body
    assert session.close_calls == 0


def test_redirect_is_rejected_without_followup_request() -> None:
    session = FakeSession(FakeResponse(307, ""))

    with pytest.raises(RedirectRejectedError):
        asyncio.run(_client(session).open_door(Door.TWO, UnlockPassword("fake-secret")))

    assert len(session.calls) == 1


def test_transport_failure_is_not_retried() -> None:
    session = FailingSession(FakeResponse(200, _SUCCESS))

    with pytest.raises(TransportError) as caught:
        asyncio.run(_client(session).open_door(Door.ONE, UnlockPassword("fake-secret")))

    assert len(session.calls) == 1
    assert "synthetic transport failure" not in str(caught.value)
    assert caught.value.__cause__ is None


def test_response_body_failure_is_sanitized_and_released() -> None:
    response = FailingResponse(200, _SUCCESS)
    session = FakeSession(response)

    with pytest.raises(TransportError) as caught:
        asyncio.run(_client(session).read_status())

    assert "synthetic response-body private detail" not in str(caught.value)
    assert caught.value.__cause__ is None
    assert response.released
    assert len(session.calls) == 1


def test_rejection_is_parsed_and_not_retried() -> None:
    response = FakeResponse(200, '<envelope><body><error>7</error></body></envelope>')
    session = FakeSession(response)

    with pytest.raises(ControlRejectedError) as caught:
        asyncio.run(_client(session).open_door(Door.ONE, UnlockPassword("fake-secret")))

    assert caught.value.protocol_code == "7"
    assert len(session.calls) == 1


@pytest.mark.parametrize("body", ["not xml", "<envelope><body /></envelope>"])
def test_malformed_or_incomplete_response_is_rejected(body: str) -> None:
    session = FakeSession(FakeResponse(200, body))

    with pytest.raises(InvalidResponseError):
        asyncio.run(_client(session).read_status())

    assert len(session.calls) == 1


@pytest.mark.parametrize(
    "case",
    json.loads(
        (Path(__file__).resolve().parents[1] / "protocol/control_responses.json").read_text()
    )["cases"],
    ids=lambda case: case["id"],
)
def test_shared_responses_through_one_shot_executor(case) -> None:
    response = FakeResponse(200, case["xml"])
    session = FakeSession(response)
    action = _client(session).open_door(Door.ONE, UnlockPassword("synthetic-secret"))
    if case["code"] is None:
        with pytest.raises(InvalidResponseError):
            asyncio.run(action)
    elif case["code"] != "0":
        with pytest.raises(ControlRejectedError) as caught:
            asyncio.run(action)
        assert caught.value.protocol_code == case["code"]
    else:
        asyncio.run(action)
    assert len(session.calls) == 1
    assert session.calls[0]["allow_redirects"] is False
    assert response.released
    assert session.close_calls == 0
