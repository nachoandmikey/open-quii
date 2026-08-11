"""Read-only status coordinator for OpenQUII."""

from __future__ import annotations

import logging
from datetime import timedelta

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .const import DOMAIN, POLL_INTERVAL_SECONDS
from .core import DeviceStatus, OpenQUIIClient, OpenQUIIError

_LOGGER = logging.getLogger(__name__)


class OpenQUIICoordinator(DataUpdateCoordinator[DeviceStatus]):
    """Coordinate the single authenticated read operation; never actuate controls."""

    def __init__(
        self,
        hass: HomeAssistant,
        entry: ConfigEntry,
        client: OpenQUIIClient,
    ) -> None:
        super().__init__(
            hass,
            _LOGGER,
            config_entry=entry,
            name=DOMAIN,
            update_interval=timedelta(seconds=POLL_INTERVAL_SECONDS),
            always_update=False,
        )
        self.client = client

    async def _async_update_data(self) -> DeviceStatus:
        """Perform one read-only status request."""
        try:
            return await self.client.read_status()
        except OpenQUIIError as error:
            raise UpdateFailed("Unable to read monitor status") from error
