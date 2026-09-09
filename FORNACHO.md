# OpenQUII: engineering notes

## One protocol, two runtimes

The Swift package is the native media/control engine. The canonical Python package
lives inside the Home Assistant integration, so building its wheel and loading the
integration reuse the same code. `protocol/` is the shared contract, rather than a
third implementation. Its synthetic JSON fixtures are executable examples consumed
by both test suites.

## A response is not a treasure hunt

Searching an XML tree for the first `0` is like reading only the first word of a
contract. A nested denial or a contradictory second result can disappear. Control
acceptance now checks the exact envelope/body path, a single leaf result, canonical
numeric spelling, and signed-64-bit bounds. An ambiguous response is terminal; it
never authorizes an automatic retry of a physical action.

## Three clocks, two kinds of evidence

TCP readiness, initial video readiness, and an established feed stopping are separate
failure modes. The video receiver bounds all three with monotonic dispatch deadlines.
H.264 SPS/PPS/IDR prerequisites are stronger than “some bytes arrived,” but still do
not prove that a decoder produced an image. The application renderer must measure
actual output independently. Audio can keep arriving while video is frozen, so it
must not refresh the video clock.

## Ownership before notification

The receiver serializes start, stop, network callbacks, and timers. On failure it
invalidates the old connection *before* notifying the application. This order matters:
a callback can start session B immediately, and cleanup for A must never stop B.
Every timer and receive callback checks the exact connection. The library makes one
attempt and leaves owner-specific recovery decisions to the application.

Tests use an explicitly loopback-bound Network.framework server, synthetic keys,
and generated records. The listener's accept handler must be installed before start,
and fixtures must consume the actual 144-byte PLAY request rather than a guessed
length. These tests establish transport behavior, not device compatibility or visible
pixels. No physical control or media acceptance should be inferred from them.

## Release boundary

GitHub tags/releases distribute the SwiftPM package and HACS custom integration.
Version strings span Swift, Python, Home Assistant, and CI import checks; update them
together. Building a wheel proves packaging, not publication to PyPI, and merging
library source does not update an application's pinned dependency or an installed HA
integration.
