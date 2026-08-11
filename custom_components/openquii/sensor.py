"""Diagnostic connectivity sensor for OpenQUII."""

from __future__ import annotations

from homeassistant.components.sensor import SensorDeviceClass, SensorEntity
from homeassistant.const import EntityCategory
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import OpenQUIIConfigEntry
from .entity import OpenQUIIEntity


async def async_setup_entry(
    hass: HomeAssistant,
    entry: OpenQUIIConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    """Set up the read-only diagnostic entity."""
    async_add_entities([OpenQUIIStatusSensor(entry)])


class OpenQUIIStatusSensor(OpenQUIIEntity, SensorEntity):
    """Expose sanitized status reachability from coordinator memory."""

    _attr_device_class = SensorDeviceClass.ENUM
    _attr_entity_category = EntityCategory.DIAGNOSTIC
    _attr_options = ["reachable"]
    _attr_translation_key = "status"

    def __init__(self, entry: OpenQUIIConfigEntry) -> None:
        super().__init__(entry)
        self._attr_unique_id = f"{entry.entry_id}_status"

    @property
    def native_value(self) -> str:
        """Return a non-secret state; coordinator availability carries failures."""
        return "reachable"
