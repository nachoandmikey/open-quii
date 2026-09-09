# Changelog

## 0.2.2 — unreleased

- Swift and Python local control now require one unambiguous, signed-64-bit result
  at the exact `envelope/body/error` or `envelope/body/result` path. Malformed XML,
  nested/misplaced/duplicate results, namespaces, DTDs, and noncanonical numbers
  fail closed. Both implementations execute the same synthetic response fixtures.
- Swift video now bounds connection/handshake, startup, and established frame-idle
  waits. Audio/control traffic and video without SPS/PPS/IDR prerequisites do not
  extend video liveness. Renderer success still requires a caller-owned deadline.
- Video start/stop/callback ownership is serialized. Terminal failure invalidates
  the old connection before calling the client; old timers cannot stop a replacement.
  The library never reconnects or retries an action automatically.
- Added synthetic loopback receiver lifecycle/deadline tests and H.264 progress tests.

### Distribution

The existing release route is a Git tag/GitHub release consumed by SwiftPM and
HACS custom repositories. Version metadata is aligned across Swift, Python, and
Home Assistant. This candidate does not publish a tag or update an installation.
The Python wheel/source archive can be built locally; no PyPI publishing workflow
is configured. A PyPI launch is a separate operation, not an implicit deployment.
