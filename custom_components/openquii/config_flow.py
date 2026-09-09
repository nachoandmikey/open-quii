"""Offline config flow for OpenQUII."""

from __future__ import annotations

from typing import Any

import voluptuous as vol
from homeassistant import config_entries
from homeassistant.config_entries import ConfigFlowResult
from homeassistant.helpers import selector

from .const import (
    CONF_ADDRESS,
    CONF_UNLOCK_CREDENTIAL_MODE,
    CONF_UNLOCK_PASSWORD,
    CONF_USERNAME,
    CONF_VERIFICATION_DIGEST,
    DOMAIN,
    UNLOCK_CREDENTIAL_MODE_PLAINTEXT,
    UNLOCK_CREDENTIAL_MODE_SHA256_DIGEST,
)
from .core import (
    AddressValidationError,
    ControlCredentials,
    ControlUsername,
    CredentialValidationError,
    UnlockPassword,
    UnlockPasswordDigest,
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
        vol.Required(
            CONF_UNLOCK_CREDENTIAL_MODE,
            default=UNLOCK_CREDENTIAL_MODE_PLAINTEXT,
        ): selector.SelectSelector(
            selector.SelectSelectorConfig(
                options=[
                    selector.SelectOptionDict(
                        value=UNLOCK_CREDENTIAL_MODE_PLAINTEXT,
                        label="Plaintext password",
                    ),
                    selector.SelectOptionDict(
                        value=UNLOCK_CREDENTIAL_MODE_SHA256_DIGEST,
                        label="Pre-encoded SHA-256 digest",
                    ),
                ],
                mode=selector.SelectSelectorMode.DROPDOWN,
            )
        ),
        vol.Required(CONF_UNLOCK_PASSWORD): _SECRET_SELECTOR,
    }
)


class OpenQUIIConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Configure one OpenQUII monitor without live or actuating validation."""

    VERSION = 2

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
                unlock_mode = user_input[CONF_UNLOCK_CREDENTIAL_MODE]
                if unlock_mode == UNLOCK_CREDENTIAL_MODE_PLAINTEXT:
                    unlock_credential = UnlockPassword(user_input[CONF_UNLOCK_PASSWORD])
                elif unlock_mode == UNLOCK_CREDENTIAL_MODE_SHA256_DIGEST:
                    unlock_credential = UnlockPasswordDigest(user_input[CONF_UNLOCK_PASSWORD])
                else:
                    raise CredentialValidationError("unlock credential mode")
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
                        CONF_UNLOCK_CREDENTIAL_MODE: unlock_mode,
                        CONF_UNLOCK_PASSWORD: unlock_credential.value,
                    },
                )

        return self.async_show_form(step_id="user", data_schema=_USER_SCHEMA, errors=errors)
