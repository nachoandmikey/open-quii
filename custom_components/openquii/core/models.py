"""Public control models whose representations contain no secrets."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import IntEnum


class Door(IntEnum):
    """The only supported user-facing door targets."""

    ONE = 1
    TWO = 2


@dataclass(frozen=True, slots=True, repr=False)
class RequestSpec:
    """An immutable request description; its body is intentionally not printable."""

    method: str
    url: str
    headers: dict[str, str]
    body: str = field(repr=False)

    def __repr__(self) -> str:
        return f"RequestSpec(method={self.method!r}, url={self.url!r}, body=<redacted>)"


@dataclass(frozen=True, slots=True)
class DeviceStatus:
    """Sanitized result of an authenticated status operation."""

    protocol_code: str
