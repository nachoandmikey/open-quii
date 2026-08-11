"""Explicit local-control credential value types."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from typing import Protocol


class CredentialValidationError(ValueError):
    """Raised when a credential has an invalid shape."""

    def __init__(self, field_name: str) -> None:
        super().__init__(f"The {field_name} credential is invalid.")


_DIGEST_PATTERN = re.compile(r"[0-9a-f]{64}", re.ASCII | re.IGNORECASE)


@dataclass(frozen=True, slots=True, repr=False)
class ControlUsername:
    """Username used only in the authenticated control header."""

    value: str = field(repr=False)

    def __post_init__(self) -> None:
        normalized = self.value.strip()
        if not normalized or len(normalized) > 64 or any(ord(char) < 0x20 for char in normalized):
            raise CredentialValidationError("username")
        object.__setattr__(self, "value", normalized)

    def __repr__(self) -> str:
        return "ControlUsername(<redacted>)"


@dataclass(frozen=True, slots=True, repr=False)
class VerificationDigest:
    """SHA-256 verification digest used only in the authenticated header."""

    value: str = field(repr=False)

    def __post_init__(self) -> None:
        normalized = self.value.strip().lower()
        if _DIGEST_PATTERN.fullmatch(normalized) is None:
            raise CredentialValidationError("verification digest")
        object.__setattr__(self, "value", normalized)

    def __repr__(self) -> str:
        return "VerificationDigest(<redacted>)"


class UnlockCredential(Protocol):
    """Credential that can supply the content-layer SHA-256 digest."""

    @property
    def sha256_digest(self) -> str:
        """Return the content-layer digest without exposing plaintext."""
        ...


@dataclass(frozen=True, slots=True, repr=False)
class UnlockPassword:
    """Plaintext unlock password that is SHA-256 encoded for transmission."""

    value: str = field(repr=False)

    def __post_init__(self) -> None:
        normalized = self.value.strip()
        if not normalized:
            raise CredentialValidationError("unlock password")
        object.__setattr__(self, "value", normalized)

    @property
    def sha256_digest(self) -> str:
        """Return the SHA-256 encoding required by the content field."""
        return hashlib.sha256(self.value.encode("utf-8")).hexdigest()

    def __repr__(self) -> str:
        return "UnlockPassword(<redacted>)"


@dataclass(frozen=True, slots=True, repr=False)
class UnlockPasswordDigest:
    """An explicitly pre-encoded SHA-256 unlock password."""

    value: str = field(repr=False)

    def __post_init__(self) -> None:
        normalized = self.value.strip().lower()
        if _DIGEST_PATTERN.fullmatch(normalized) is None:
            raise CredentialValidationError("unlock password digest")
        object.__setattr__(self, "value", normalized)

    @property
    def sha256_digest(self) -> str:
        """Return the already encoded content-layer digest."""
        return self.value

    def __repr__(self) -> str:
        return "UnlockPasswordDigest(<redacted>)"


@dataclass(frozen=True, slots=True, repr=False)
class ControlCredentials:
    """Header credentials, kept structurally separate from unlock authorization."""

    username: ControlUsername = field(repr=False)
    verification_digest: VerificationDigest = field(repr=False)

    def __repr__(self) -> str:
        return "ControlCredentials(<redacted>)"
