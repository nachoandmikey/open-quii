"""Pure policy boundary for consequential Home Assistant actions."""

from __future__ import annotations


def is_authenticated_user_action(user_id: str | None) -> bool:
    """Return whether a service context represents an authenticated HA user."""
    return bool(user_id and user_id.strip())
