"""Constants for the OpenQUII Home Assistant integration."""

from typing import Final

DOMAIN: Final = "openquii"

CONF_ADDRESS: Final = "address"
CONF_USERNAME: Final = "username"
CONF_VERIFICATION_DIGEST: Final = "verification_digest"
CONF_UNLOCK_PASSWORD: Final = "unlock_password"
CONF_UNLOCK_CREDENTIAL_MODE: Final = "unlock_credential_mode"

UNLOCK_CREDENTIAL_MODE_PLAINTEXT: Final = "plaintext"
UNLOCK_CREDENTIAL_MODE_SHA256_DIGEST: Final = "sha256_digest"

POLL_INTERVAL_SECONDS: Final = 60
