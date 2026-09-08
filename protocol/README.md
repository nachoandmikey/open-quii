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

A response is successful only when the HTTP status is 2xx and the response
satisfies **all** of this fail-closed contract:

- Well-formed XML, with an exact, unnamespaced `envelope` root and exactly one
  direct `body` child. Element names are case-sensitive; namespaced elements
  are not a supported response dialect.
- Exactly one `error` **or** `result` element in the entire document, located
  directly at `envelope/body/error` or `envelope/body/result`. Duplicate values
  (even equal ones), mixed error/result values, misplaced codes, and child
  elements within the code are invalid. Unrelated metadata is permitted.
- The code, after trimming only XML whitespace (space, tab, CR, LF), matches
  `0|-?[1-9][0-9]*` and fits a signed 64-bit integer. Thus only literal `0`
  means accepted; canonical nonzero values mean rejected. Empty, nonnumeric,
  overflow, signed-zero, plus-prefixed, and leading-zero values are invalid.
- DTDs are forbidden and external entities are not resolved. CDATA and normal
  XML character references may supply code text. Responses are limited to
  1 MiB of UTF-8; Swift requires UTF-8 bytes, while Python takes decoded text
  and applies the limit to its UTF-8 representation.

Invalid/contradictory responses are **not** evidence of either physical success
or definite device rejection. They remain uncertain and must never cause an
automatic retry. This intentionally replaces the older first-code-wins and
namespace-stripping behavior.

`control_responses.json` is the normative shared synthetic acceptance/rejection
corpus. Both runtimes run it through their parser and one-shot executor with
in-memory responses; no device is needed. Existing redirect tests remain in
place (Swift also exercises a real loopback 307).

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
