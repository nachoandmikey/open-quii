"""Deterministic XML request construction for the local-control contract."""

from __future__ import annotations

from xml.sax.saxutils import escape

from .address import MonitorAddress, canonicalize_monitor_address
from .credentials import ControlCredentials, UnlockCredential
from .models import Door, RequestSpec

_CONTENT_TYPE = "application/xml; charset=utf-8"
_STATUS_COMMAND = "get.device.status"
_OPEN_COMMAND = "set.device.opendoor"
_LOCK_NUMBER = 1


def build_status_request(
    monitor_address: str | MonitorAddress,
    credentials: ControlCredentials,
) -> RequestSpec:
    """Build the only authenticated read request in the current contract."""
    return _build_request(
        monitor_address,
        credentials,
        _STATUS_COMMAND,
        "<content></content>",
    )


def build_open_door_request(
    monitor_address: str | MonitorAddress,
    credentials: ControlCredentials,
    unlock_credential: UnlockCredential,
    door: Door,
) -> RequestSpec:
    """Build one Door 1/2, Lock 1 request without executing it."""
    if not isinstance(door, Door):
        raise TypeError("door must be a Door value")
    content = (
        "<content>"
        f"<door>{door.value}</door>"
        f"<locknumber>{_LOCK_NUMBER}</locknumber>"
        f"<password>{unlock_credential.sha256_digest}</password>"
        "</content>"
    )
    return _build_request(monitor_address, credentials, _OPEN_COMMAND, content)


def _build_request(
    monitor_address: str | MonitorAddress,
    credentials: ControlCredentials,
    command: str,
    content: str,
) -> RequestSpec:
    address = (
        monitor_address
        if isinstance(monitor_address, MonitorAddress)
        else canonicalize_monitor_address(monitor_address)
    )
    username = escape(credentials.username.value)
    verification_digest = credentials.verification_digest.value
    body = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<envelope><header><security>username</security>"
        f"<username>{username}</username>"
        f"<password>{verification_digest}</password>"
        "<passwordencode>1</passwordencode></header><body>"
        f"<command>{command}</command>{content}</body></envelope>"
    )
    return RequestSpec(
        method="POST",
        url=address.control_url,
        headers={"Content-Type": _CONTENT_TYPE, "Connection": "close"},
        body=body,
    )
