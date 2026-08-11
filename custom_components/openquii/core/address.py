"""Strict monitor-address validation shared by standalone and HA consumers."""

from __future__ import annotations

import re
from dataclasses import dataclass


class AddressValidationError(ValueError):
    """Raised when an address is not a canonical local IPv4 HTTP origin."""

    def __init__(self) -> None:
        super().__init__("The monitor address must be a canonical local IPv4 HTTP origin.")


_ADDRESS_PATTERN = re.compile(
    r"^(?:(?P<scheme>https?)://)?"
    r"(?P<host>[0-9]{1,3}(?:\.[0-9]{1,3}){3})"
    r"(?::(?P<port>[0-9]{1,5}))?/?$",
    re.ASCII | re.IGNORECASE,
)


@dataclass(frozen=True, slots=True)
class MonitorAddress:
    """A validated and canonical local monitor origin."""

    base_url: str
    host: str
    port: int | None

    @property
    def control_url(self) -> str:
        """Return the fixed local-control endpoint."""
        return f"{self.base_url}/tdkcgi"


def canonicalize_monitor_address(value: str) -> MonitorAddress:
    """Validate and canonicalize a literal private, link-local, or loopback IPv4 origin."""
    match = _ADDRESS_PATTERN.fullmatch(value.strip())
    if match is None:
        raise AddressValidationError

    host = match.group("host")
    octets = host.split(".")
    if any((len(part) > 1 and part.startswith("0")) or int(part) > 255 for part in octets):
        raise AddressValidationError
    numbers = tuple(int(part) for part in octets)
    first, second, _, _ = numbers
    permitted = (
        first == 10
        or (first == 172 and 16 <= second <= 31)
        or (first == 192 and second == 168)
        or (first == 169 and second == 254)
        or first == 127
    )
    if not permitted:
        raise AddressValidationError

    raw_port = match.group("port")
    port: int | None = None
    if raw_port is not None:
        if (len(raw_port) > 1 and raw_port.startswith("0")) or not 1 <= int(raw_port) <= 65_535:
            raise AddressValidationError
        port = int(raw_port)

    scheme = (match.group("scheme") or "http").lower()
    base_url = f"{scheme}://{host}" + (f":{port}" if port is not None else "")
    return MonitorAddress(base_url=base_url, host=host, port=port)
