"""Redacted diagnostics for OpenQUII."""

from __future__ import annotations

from typing import Any

from homeassistant.components.diagnostics import async_redact_data
from homeassistant.core import HomeAssistant

from . import OpenQUIIConfigEntry
from .const import (
    CONF_ADDRESS,
    CONF_UNLOCK_PASSWORD,
    CONF_USERNAME,
    CONF_VERIFICATION_DIGEST,
)

_TO_REDACT = {
    CONF_ADDRESS,
    CONF_USERNAME,
    CONF_VERIFICATION_DIGEST,
    CONF_UNLOCK_PASSWORD,
}


async def async_get_config_entry_diagnostics(
    hass: HomeAssistant,
    entry: OpenQUIIConfigEntry,
) -> dict[str, Any]:
    """Return diagnostics with every supplied value redacted."""
    coordinator = entry.runtime_data.coordinator
    return {
        "entry_data": async_redact_data(dict(entry.data), _TO_REDACT),
        "last_update_success": coordinator.last_update_success,
        "protocol_code": (
            coordinator.data.protocol_code if coordinator.last_update_success else None
        ),
    }
