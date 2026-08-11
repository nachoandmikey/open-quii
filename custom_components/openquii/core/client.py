"""Caller-session-owned, one-shot asynchronous local-control client."""

from __future__ import annotations

from collections.abc import Awaitable, Mapping
from typing import Protocol
from xml.etree import ElementTree

from .address import MonitorAddress, canonicalize_monitor_address
from .credentials import ControlCredentials, UnlockCredential
from .models import DeviceStatus, Door, RequestSpec
from .requests import build_open_door_request, build_status_request

_MAXIMUM_RESPONSE_CHARACTERS = 1_048_576


class OpenQUIIError(Exception):
    """Base class for sanitized protocol and transport-facing failures."""


class RedirectRejectedError(OpenQUIIError):
    """A response attempted to redirect a local control request."""

    def __init__(self) -> None:
        super().__init__("The monitor redirect was rejected.")


class TransportError(OpenQUIIError):
    """The caller-owned transport failed without exposing its raw details."""

    def __init__(self) -> None:
        super().__init__("The monitor transport failed.")


class HTTPResponseError(OpenQUIIError):
    """The monitor returned an unsuccessful non-redirect HTTP response."""

    def __init__(self, status: int) -> None:
        self.status = status
        super().__init__(f"The monitor returned HTTP status {status}.")


class InvalidResponseError(OpenQUIIError):
    """The monitor returned malformed or incomplete protocol XML."""

    def __init__(self) -> None:
        super().__init__("The monitor returned an invalid protocol response.")


class ControlRejectedError(OpenQUIIError):
    """The monitor rejected an authenticated operation."""

    def __init__(self, protocol_code: str) -> None:
        self.protocol_code = protocol_code
        super().__init__(f"The monitor rejected the operation ({protocol_code}).")


class AsyncResponse(Protocol):
    """The minimal aiohttp-like response surface used by the core."""

    status: int

    async def text(self) -> str:
        """Read the response as text."""
        ...

    def release(self) -> None:
        """Release this response without closing the caller's session."""
        ...


class AsyncSession(Protocol):
    """The minimal caller-owned aiohttp-like session surface used by the core."""

    def request(
        self,
        method: str,
        url: str,
        *,
        data: bytes,
        headers: Mapping[str, str],
        allow_redirects: bool,
        timeout: float,
    ) -> Awaitable[AsyncResponse]:
        """Execute exactly one HTTP request."""
        ...


class OpenQUIIClient:
    """Authenticated local-control client with no retry or session ownership."""

    def __init__(
        self,
        session: AsyncSession,
        monitor_address: str,
        credentials: ControlCredentials,
        *,
        timeout: float = 8.0,
    ) -> None:
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        self._session = session
        self._address: MonitorAddress = canonicalize_monitor_address(monitor_address)
        self._credentials = credentials
        self._timeout = timeout

    @property
    def monitor_address(self) -> str:
        """Return the canonical non-secret monitor origin."""
        return self._address.base_url

    async def read_status(self) -> DeviceStatus:
        """Perform one authenticated, non-actuating status request."""
        request = build_status_request(self._address, self._credentials)
        return await self._execute(request)

    async def open_door(self, door: Door, unlock_credential: UnlockCredential) -> None:
        """Perform exactly one request for one explicit Door 1/2 action."""
        request = build_open_door_request(
            self._address,
            self._credentials,
            unlock_credential,
            door,
        )
        await self._execute(request)

    async def _execute(self, request: RequestSpec) -> DeviceStatus:
        # There is deliberately one transport invocation and no retry wrapper.
        try:
            response = await self._session.request(
                request.method,
                request.url,
                data=request.body.encode("utf-8"),
                headers=request.headers,
                allow_redirects=False,
                timeout=self._timeout,
            )
        except Exception as error:
            raise TransportError from error
        try:
            if 300 <= response.status < 400:
                raise RedirectRejectedError
            if not 200 <= response.status < 300:
                raise HTTPResponseError(response.status)
            body = await response.text()
            code = _parse_protocol_code(body)
            if code != "0":
                raise ControlRejectedError(code)
            return DeviceStatus(protocol_code=code)
        except OpenQUIIError:
            raise
        except Exception as error:
            raise TransportError from error
        finally:
            response.release()


def _parse_protocol_code(body: str) -> str:
    if len(body) > _MAXIMUM_RESPONSE_CHARACTERS:
        raise InvalidResponseError
    try:
        root = ElementTree.fromstring(body)
    except ElementTree.ParseError as error:
        raise InvalidResponseError from error

    # An explicit error wins even when a malformed response also includes result.
    for expected_name in ("error", "result"):
        for element in root.iter():
            local_name = element.tag.rsplit("}", 1)[-1].lower()
            if local_name == expected_name and element.text is not None:
                code = element.text.strip()
                if code:
                    return code
    raise InvalidResponseError
