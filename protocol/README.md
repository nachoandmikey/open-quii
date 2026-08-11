# OpenQUII local-control contract

This directory is the language-neutral contract shared by the Swift package and
the canonical Python core. All values are synthetic. These files are protocol
documentation and test vectors, not device captures.

## Monitor address

A monitor address is an `http` or `https` origin whose host is a canonical,
literal IPv4 address in exactly one of these ranges:

- RFC 1918: `10/8`, `172.16/12`, or `192.168/16`;
- IPv4 link-local: `169.254/16`;
- IPv4 loopback: `127/8`.

The scheme may be omitted, in which case `http` is used. A port from 1 through
65535 and one trailing slash are allowed. Surrounding whitespace is ignored.
Each IPv4 octet is decimal ASCII, contains no leading zero unless it is exactly
`0`, and is in the range 0 through 255.

Hostnames, IPv6, integer/hex/octal IPv4 forms, user information, paths, queries,
fragments, malformed ports, and public addresses are rejected. Canonicalization
lowercases the scheme, removes a trailing slash, and never resolves DNS.

See `addresses.json` for normative accepted and rejected examples.

## Authentication and credential separation

Control uses an XML envelope sent as an HTTP `POST` to `/tdkcgi` with
`Content-Type: application/xml; charset=utf-8`. Three input fields have distinct
types and must not be substituted for one another:

1. The username identifies the local control principal.
2. The verification digest is exactly 32 bytes represented by 64 hexadecimal
   characters. It appears only in the authenticated header password field.
3. The unlock password is authorization material for an open-door action. A
   plaintext value is SHA-256 encoded before use, while a value already supplied
   as a digest must be explicitly typed as such. Its digest appears only in the
   control content password field.

Implementations must XML-escape text fields, must not log complete request bodies
or credentials, and must not persist credentials. Integrations may persist them
only in their platform's designated secret-bearing configuration store.

## Read and control operations

`get.device.status` is the authenticated read operation. It contains an empty
`content` element and can be used for health polling. It can never open a door.

`set.device.opendoor` is the only operation in the current cross-language control
contract. The target mapping is fixed:

| User-facing target | `door` | `locknumber` |
| --- | ---: | ---: |
| Door 1 | 1 | 1 |
| Door 2 | 2 | 1 |

No other door or lock value is valid. One explicit, authenticated user action
authorizes exactly one HTTP request. Implementations must disable redirects and
must reject every 3xx response even if the injected transport returns one. They
must not retry, confirm by a second control request, or actuate during discovery,
configuration, startup, polling, diagnostics, or background refresh.

A response is successful only when it is well-formed XML, the HTTP status is
successful, and the first protocol `error` or `result` value is `0`. A nonzero
protocol value is a rejection. An absent value or malformed XML is invalid. An
ambiguous transport result remains ambiguous and must never be retried
automatically.

`control_requests.json` contains normative cross-runtime XML construction vectors.
`framing_vectors.json` contains sanitized, generated reference vectors for the
Swift-only media/talk surface; it is not currently an executable Python fixture.

## Scope and safety

The canonical Python core currently covers local authenticated status and the two
one-shot door controls. The Swift package also contains experimental media and
talk components. Those components are not yet part of the cross-language Python
contract.

Applications must make door actuation conspicuous and user initiated. They must
keep ring receipt, answering, microphone use, media streaming, and door control
as separate capabilities.
