"""Canonical Python core for the OpenQUII local-control contract."""

from .address import AddressValidationError, MonitorAddress, canonicalize_monitor_address
from .client import (
    AsyncResponse,
    AsyncSession,
    ControlRejectedError,
    HTTPResponseError,
    InvalidResponseError,
    OpenQUIIClient,
    OpenQUIIError,
    RedirectRejectedError,
    TransportError,
)
from .credentials import (
    ControlCredentials,
    ControlUsername,
    CredentialValidationError,
    UnlockCredential,
    UnlockPassword,
    UnlockPasswordDigest,
    VerificationDigest,
)
from .models import DeviceStatus, Door, RequestSpec
from .requests import build_open_door_request, build_status_request

__all__ = [
    "AddressValidationError",
    "AsyncResponse",
    "AsyncSession",
    "ControlCredentials",
    "ControlRejectedError",
    "ControlUsername",
    "CredentialValidationError",
    "DeviceStatus",
    "Door",
    "HTTPResponseError",
    "InvalidResponseError",
    "MonitorAddress",
    "OpenQUIIClient",
    "OpenQUIIError",
    "RedirectRejectedError",
    "RequestSpec",
    "TransportError",
    "UnlockCredential",
    "UnlockPassword",
    "UnlockPasswordDigest",
    "VerificationDigest",
    "build_open_door_request",
    "build_status_request",
    "canonicalize_monitor_address",
]

__version__ = "0.2.2"
