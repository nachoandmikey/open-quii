"""Explicit, authenticated-user-only OpenQUII door buttons."""

from __future__ import annotations

from dataclasses import dataclass

from homeassistant.components.button import ButtonEntity
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import OpenQUIIConfigEntry
from .const import (
    CONF_UNLOCK_CREDENTIAL_MODE,
    CONF_UNLOCK_PASSWORD,
    UNLOCK_CREDENTIAL_MODE_PLAINTEXT,
    UNLOCK_CREDENTIAL_MODE_SHA256_DIGEST,
)
from .control_policy import is_authenticated_user_action
from .core import Door, OpenQUIIError, UnlockPassword, UnlockPasswordDigest
from .entity import OpenQUIIEntity


@dataclass(frozen=True, slots=True)
class OpenQUIIButtonDescription:
    """Static, non-secret mapping from entity to protocol target."""

    translation_key: str
    door: Door


_BUTTONS = (
    OpenQUIIButtonDescription("door_1", Door.ONE),
    OpenQUIIButtonDescription("door_2", Door.TWO),
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: OpenQUIIConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    """Set up the two explicit one-shot control buttons."""
    async_add_entities(OpenQUIIDoorButton(entry, description) for description in _BUTTONS)


class OpenQUIIDoorButton(OpenQUIIEntity, ButtonEntity):
    """Open one fixed door only when an authenticated HA user pressed the entity."""

    def __init__(
        self,
        entry: OpenQUIIConfigEntry,
        description: OpenQUIIButtonDescription,
    ) -> None:
        super().__init__(entry)
        self._description = description
        self._attr_translation_key = description.translation_key
        self._attr_unique_id = f"{entry.entry_id}_{description.translation_key}"

    async def async_press(self) -> None:
        """Issue exactly one request for an authenticated service context."""
        context = self._context
        user_id = context.user_id if context is not None else None
        if not is_authenticated_user_action(user_id):
            raise HomeAssistantError(
                "Door control requires an authenticated Home Assistant user."
            )
        user = await self.hass.auth.async_get_user(user_id)
        if user is None:
            raise HomeAssistantError(
                "Door control requires an authenticated Home Assistant user."
            )

        unlock_value = self._entry.data[CONF_UNLOCK_PASSWORD]
        unlock_mode = self._entry.data.get(
            CONF_UNLOCK_CREDENTIAL_MODE,
            UNLOCK_CREDENTIAL_MODE_PLAINTEXT,
        )
        if unlock_mode == UNLOCK_CREDENTIAL_MODE_PLAINTEXT:
            unlock_credential = UnlockPassword(unlock_value)
        elif unlock_mode == UNLOCK_CREDENTIAL_MODE_SHA256_DIGEST:
            unlock_credential = UnlockPasswordDigest(unlock_value)
        else:
            raise HomeAssistantError("The configured unlock credential mode is invalid.")
        try:
            await self.coordinator.client.open_door(
                self._description.door,
                unlock_credential,
            )
        except OpenQUIIError as error:
            # Keep transport and credential details out of HA logs and state.
            raise HomeAssistantError("The monitor did not confirm door control.") from error
