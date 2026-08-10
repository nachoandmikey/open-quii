# Security Policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository. Do not open a public issue containing credentials, device identifiers, local network details, packet captures, or a working exploit.

## Operational safety

OpenQUII consumers must treat door actuation as consequential:

- require an explicit foreground user action;
- issue one request per action;
- do not automatically retry uncertain outcomes;
- keep ring receipt, call answer, microphone activation, and unlock as separate permissions/actions;
- never log credentials or complete authenticated payloads.
