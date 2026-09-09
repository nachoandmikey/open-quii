"""Pure policy boundary for consequential Home Assistant actions."""

from __future__ import annotations

from typing import Protocol


class HomeAssistantUser(Protocol):
    """Minimal HA user properties needed by the physical-control policy."""

    is_active: bool
    system_generated: bool


def is_authenticated_user_action(user_id: str | None) -> bool:
    """Return whether a service context names an HA user for resolution."""
    return bool(user_id and user_id.strip())


def is_authenticated_human_user(user: HomeAssistantUser | None) -> bool:
    """Require a current, active, non-system user before physical control."""
    return bool(user is not None and user.is_active and not user.system_generated)
