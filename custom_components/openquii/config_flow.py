"""Offline config flow for OpenQUII."""

from __future__ import annotations

from typing import Any

import voluptuous as vol
from homeassistant import config_entries
from homeassistant.config_entries import ConfigFlowResult
from homeassistant.helpers import selector

from .const import (
    CONF_ADDRESS,
    CONF_UNLOCK_PASSWORD,
    CONF_USERNAME,
    CONF_VERIFICATION_DIGEST,
    DOMAIN,
)
from .core import (
    AddressValidationError,
    ControlCredentials,
    ControlUsername,
    CredentialValidationError,
    UnlockPassword,
    VerificationDigest,
    canonicalize_monitor_address,
)

_SECRET_SELECTOR = selector.TextSelector(
    selector.TextSelectorConfig(type=selector.TextSelectorType.PASSWORD)
)

_USER_SCHEMA = vol.Schema(
    {
        vol.Required(CONF_ADDRESS): str,
        vol.Required(CONF_USERNAME): str,
        vol.Required(CONF_VERIFICATION_DIGEST): _SECRET_SELECTOR,
        vol.Required(CONF_UNLOCK_PASSWORD): _SECRET_SELECTOR,
    }
)


class OpenQUIIConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Configure one OpenQUII monitor without live or actuating validation."""

    VERSION = 1

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Validate local shapes only; setup never opens a door."""
        errors: dict[str, str] = {}
        if user_input is not None:
            try:
                address = canonicalize_monitor_address(user_input[CONF_ADDRESS])
                credentials = ControlCredentials(
                    username=ControlUsername(user_input[CONF_USERNAME]),
                    verification_digest=VerificationDigest(
                        user_input[CONF_VERIFICATION_DIGEST]
                    ),
                )
                unlock_password = UnlockPassword(user_input[CONF_UNLOCK_PASSWORD])
            except (AddressValidationError, CredentialValidationError):
                errors["base"] = "invalid_input"
            else:
                await self.async_set_unique_id(address.base_url)
                self._abort_if_unique_id_configured()
                return self.async_create_entry(
                    title="OpenQUII monitor",
                    data={
                        CONF_ADDRESS: address.base_url,
                        CONF_USERNAME: credentials.username.value,
                        CONF_VERIFICATION_DIGEST: credentials.verification_digest.value,
                        CONF_UNLOCK_PASSWORD: unlock_password.value,
                    },
                )

        return self.async_show_form(step_id="user", data_schema=_USER_SCHEMA, errors=errors)
