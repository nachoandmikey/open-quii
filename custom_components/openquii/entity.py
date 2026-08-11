"""Common Home Assistant entity behavior for OpenQUII."""

from __future__ import annotations

from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from . import OpenQUIIConfigEntry
from .const import DOMAIN
from .coordinator import OpenQUIICoordinator


class OpenQUIIEntity(CoordinatorEntity[OpenQUIICoordinator]):
    """Base entity linked to the read-only status coordinator."""

    _attr_has_entity_name = True

    def __init__(self, entry: OpenQUIIConfigEntry) -> None:
        super().__init__(entry.runtime_data.coordinator)
        self._entry = entry
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            name=entry.title,
        )
