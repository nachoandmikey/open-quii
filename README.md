# OpenQUII

Open-source Swift building blocks for compatible QUII-based IP intercoms.

OpenQUII provides:

- validated local monitor addressing;
- authenticated local control request construction;
- encrypted QUII video and audio record parsing;
- native receive-only video/audio transport;
- explicit, user-initiated two-way talk transport.

## Status

**Experimental core available.** The reusable Swift package and synthetic protocol tests are now present. Compatibility varies by intercom model and firmware. Door control is consequential: applications must require an explicit user action, send at most one request per action, and never automatically retry an ambiguous result.

## Installation

Add this repository as a Swift Package dependency and import `OpenQUII`.

```swift
.package(url: "https://github.com/nachoandmikey/open-quii.git", from: "0.1.0")
```

## API example

Credentials must be supplied explicitly by the integrating application. This example uses synthetic values only:

```swift
import Foundation
import OpenQUII

let host = "192.168.50.10"
let digest = String(repeating: "a", count: 64)
let key = Data(repeating: 0x11, count: 32)

let videoCredentials = try QuiiNativeVideoCredentials(
    host: host,
    passwordDigest: digest,
    dataEncodeKey: key
)

// One explicit user action maps to one request. Do not retry an ambiguous result.
let control = LocalQualvisionClient()
try await control.openDoor(
    monitorAddress: host,
    verificationCode: digest,
    unlockPassword: "user-supplied-unlock-secret",
    door: 1
)

// Construction does not connect or acknowledge a call.
let talkCredentials = try QuiiTalkCredentials(
    video: videoCredentials,
    compactOEMID: "SYNTHETICOEM",
    clientID: "synthetic-client"
)
let talk = try QuiiNativeTalkTransport(credentials: talkCredentials)

// Call connect only after the user explicitly chooses to answer/talk.
try await talk.connect(
    onState: { status in print(status) },
    onAudio: { frame in /* enqueue PCM audio */ },
    onFailure: { error in /* present the failure */ }
)
```

Do not print real credentials or retain them beyond your application’s required credential lifecycle.

## Safety and privacy

OpenQUII does not contain credentials, vendor binaries, packet captures, installation identifiers, cloud deployment code, or device-specific configuration. Credentials are accepted explicitly at runtime and are never derived, persisted, or logged by the package.

The library does not automatically answer calls, acknowledge talk receipt, activate microphones, open doors, retry door actions, or start passive media monitoring. Those decisions belong to the integrating application and its user interface.

Local control accepts only private, link-local, or loopback IPv4 endpoints and rejects redirects. Native media credentials additionally support explicitly provided tailnet DNS relay hosts.

## Compatibility

The package targets iOS 17+ and macOS 14+ using Foundation, Network.framework, CryptoKit, and CommonCrypto. Run the package tests with `swift test` on macOS.

## Legal

OpenQUII is an independent interoperability project. It is not affiliated with or endorsed by Golmar, Qualvision, or their partners. Product names may be trademarks of their respective owners.

Licensed under the MIT License.
