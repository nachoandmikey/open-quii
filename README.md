# OpenQUII

Open-source, cross-platform building blocks for compatible QUII-based IP intercoms.

OpenQUII is one public source of truth with multiple runtime implementations:

- `protocol/`: language-neutral safety contract and synthetic golden fixtures;
- `Sources/OpenQUII/`: Swift runtime consumed by native apps such as Portero;
- `custom_components/openquii/core/`: canonical Python local-control runtime;
- `custom_components/openquii/`: thin Home Assistant custom integration using that same Python source.

The Python distribution maps the import name `openquii` directly to
`custom_components/openquii/core/`. There is no second or generated copy of the
Python protocol implementation.

## Status

**Experimental interoperability project.** Compatibility varies by intercom model
and firmware. Door control is consequential: applications must require an explicit
user action, send at most one request per action, reject redirects, and never retry
an ambiguous result automatically.

Current feature coverage:

- Swift: local status/control, encrypted video/audio receive parsing and transport,
  plus explicit user-initiated talk transport;
- Python: local authenticated status and one-shot Door 1/Door 2 control;
- Home Assistant: read-only reachability and authenticated-user-only Door 1/Door 2
  buttons.

Python/Home Assistant media, talk, cloud ring delivery, and call presentation are
**not implemented**. The integration does not claim parity with the Swift media
runtime yet.

## Shared protocol contract

[`protocol/README.md`](protocol/README.md) defines the current cross-language local
control contract. Swift and Python tests both consume the normative address and
control-request fixtures for:

- strict private/link-local/loopback literal IPv4 addressing;
- separate username, verification digest, and unlock credential fields;
- authenticated read/status requests;
- Door 1 and Door 2 controls, both using Lock 1;
- one request per accepted action, redirects rejected, no automatic retry.

The synthetic framing vectors remain language-neutral reference data for the
Swift-only media/talk surface; Python media parity is intentionally out of scope.

The fixtures are generated examples, not packet captures or private installation
data.

## Swift package

After the `0.2.0` release, add this repository as a Swift Package dependency:

```swift
.package(url: "https://github.com/nachoandmikey/open-quii.git", from: "0.2.0")
```

The existing stable `0.1.0` tag remains available for consumers pinned to that
release.

```swift
import OpenQUII

let monitor = "192.168.50.10" // synthetic example
let digest = String(repeating: "a", count: 64)

let control = LocalQualvisionClient()
try await control.openDoor(
    monitorAddress: monitor,
    verificationCode: digest,
    unlockCredential: .plaintext("user-supplied-secret"),
    door: 1
)
```

Use `.sha256Digest(...)` only when the caller already holds a validated
64-character digest. The source-compatible `unlockPassword:` overload handles
ordinary plaintext, but rejects an ambiguous 64-hex string instead of guessing;
use an explicit credential case for that input shape.

Construction of media/talk types does not connect, answer, activate a microphone,
or open a door. The caller must initiate those operations explicitly.

## Python core

The `openquii` package is designed for Python 3.12+ and uses an injected aiohttp-like
session. The caller owns the session and all networking lifecycle.

Before the PyPI release, install a development checkout with:

```bash
uv pip install -e /path/to/open-quii
```

```python
from openquii import (
    ControlCredentials,
    ControlUsername,
    Door,
    OpenQUIIClient,
    UnlockPassword,
    VerificationDigest,
)

credentials = ControlCredentials(
    ControlUsername("user-supplied-name"),
    VerificationDigest("a" * 64),
)
client = OpenQUIIClient(aiohttp_session, "192.168.50.10", credentials)

# Invoke only from an explicit user action. Exactly one POST is attempted.
await client.open_door(Door.ONE, UnlockPassword("user-supplied-secret"))
```

The core never creates/closes the injected session, follows redirects, retries,
persists credentials, or logs request bodies.

## Home Assistant

The repository contains a HACS-compatible custom integration under
`custom_components/openquii`.

Development installation:

1. Copy `custom_components/openquii` into the Home Assistant configuration
   directory's `custom_components/` folder.
2. Restart Home Assistant.
3. Add **OpenQUII** from **Settings → Devices & services**.
4. Enter a literal local monitor IPv4 origin and the installation credentials.

Setup validates values offline and never actuates a door. The coordinator polls only
`get.device.status`. Door buttons require a service context carrying an authenticated
Home Assistant `user_id`; automation/background contexts are rejected. Each accepted
press makes exactly one control request. Startup, setup, polling, diagnostics, and
notifications cannot unlock.

Credentials are stored only in Home Assistant config-entry data, its designated
secret-bearing configuration store. Diagnostics redact address, username,
verification digest, and unlock password.

A formal HACS default-repository listing and a Home Assistant Core submission are
separate future review processes; this integration can be installed as a HACS custom
repository once `0.2.0` is released.

## Development and verification

```bash
swift test
uv sync --extra dev
uv run pytest
uv run ruff check .
uv run mypy
uv build
```

CI also installs the built wheel into a clean environment and imports `openquii`
from outside the repository.

## Safety and privacy

OpenQUII contains no credentials, vendor binaries/source, packet captures, private
installation identifiers, cloud deployment resources, APNs/CallKit configuration,
or device-specific defaults. Credentials are supplied explicitly at runtime.

The project does not automatically answer calls, activate microphones, open doors,
retry door actions, or start passive media monitoring. Ring receipt, answering,
media, talk, and unlock remain separate capabilities.

Local control accepts only canonical private, link-local, or loopback literal IPv4
origins and rejects redirects. Native Swift media credentials additionally support
explicitly supplied tailnet relay hosts.

## Legal

OpenQUII is an independent interoperability project. It is not affiliated with or
endorsed by Golmar, Qualvision, or their partners. Product names may be trademarks
of their respective owners.

Licensed under the MIT License.
