# OpenQUII

Open-source building blocks for compatible QUII-based IP intercoms.

OpenQUII provides a reusable Swift package for:

- validated local monitor addressing;
- authenticated local control request construction;
- encrypted QUII video and audio record parsing;
- native receive-only video/audio transport;
- explicit, user-initiated two-way talk transport.

## Status

**Experimental.** The first release is being extracted from a physically tested private client, but compatibility varies by intercom model and firmware. Door control is consequential: applications must require an explicit user action, send at most one request per action, and never automatically retry an ambiguous result.

## Installation

Add this repository as a Swift Package dependency and import `OpenQUII`.

```swift
.package(url: "https://github.com/nachoandmikey/open-quii.git", from: "0.1.0")
```

## Safety and privacy

OpenQUII does not contain credentials, vendor binaries, packet captures, installation identifiers, cloud deployment code, or device-specific configuration. Credentials are accepted explicitly at runtime and are never derived, persisted, or logged by the package.

The library does not automatically answer calls, activate microphones, open doors, retry door actions, or start passive media monitoring. Those decisions belong to the integrating application and its user interface.

## Compatibility

The initial implementation targets Apple platforms using Foundation, Network.framework, CryptoKit, and CommonCrypto. A Home Assistant/Python adapter will be developed against the same public protocol fixtures rather than private app code.

## Legal

OpenQUII is an independent interoperability project. It is not affiliated with or endorsed by Golmar, Qualvision, or their partners. Product names may be trademarks of their respective owners.

Licensed under the MIT License.
