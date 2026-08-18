"""Home Assistant setup for OpenQUII."""

from __future__ import annotations

from dataclasses import dataclass

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from .const import (
    CONF_ADDRESS,
    CONF_UNLOCK_CREDENTIAL_MODE,
    CONF_USERNAME,
    CONF_VERIFICATION_DIGEST,
    UNLOCK_CREDENTIAL_MODE_PLAINTEXT,
)
from .coordinator import OpenQUIICoordinator
from .core import ControlCredentials, ControlUsername, OpenQUIIClient, VerificationDigest

PLATFORMS: list[Platform] = [Platform.BUTTON, Platform.SENSOR]


@dataclass(slots=True)
class OpenQUIIRuntimeData:
    """Non-persisted runtime objects derived from config-entry data."""

    coordinator: OpenQUIICoordinator


type OpenQUIIConfigEntry = ConfigEntry[OpenQUIIRuntimeData]


async def async_setup_entry(hass: HomeAssistant, entry: OpenQUIIConfigEntry) -> bool:
    """Set up OpenQUII from a config entry."""
    credentials = ControlCredentials(
        username=ControlUsername(entry.data[CONF_USERNAME]),
        verification_digest=VerificationDigest(entry.data[CONF_VERIFICATION_DIGEST]),
    )
    client = OpenQUIIClient(
        async_get_clientsession(hass),
        entry.data[CONF_ADDRESS],
        credentials,
    )
    coordinator = OpenQUIICoordinator(hass, entry, client)
    await coordinator.async_config_entry_first_refresh()
    entry.runtime_data = OpenQUIIRuntimeData(coordinator=coordinator)
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: OpenQUIIConfigEntry) -> bool:
    """Unload an OpenQUII config entry."""
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)


async def async_migrate_entry(hass: HomeAssistant, entry: OpenQUIIConfigEntry) -> bool:
    """Make the legacy implicit plaintext mode explicit without guessing values."""
    if entry.version == 1:
        data = dict(entry.data)
        data[CONF_UNLOCK_CREDENTIAL_MODE] = UNLOCK_CREDENTIAL_MODE_PLAINTEXT
        hass.config_entries.async_update_entry(entry, data=data, version=2)
    return True
