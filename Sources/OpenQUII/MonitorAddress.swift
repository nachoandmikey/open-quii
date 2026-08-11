import Foundation

/// Validation and canonicalization for monitor control endpoints.
public enum MonitorAddress {
    public enum ValidationError: Error, Equatable {
        case invalid
    }

    /// Returns an HTTP(S) base URL only when the host is a canonical private or local IPv4 literal.
    public static func canonicalBaseAddress(_ input: String) throws -> String {
        try validatedAddress(input).baseAddress
    }

    /// Returns the validated private or local IPv4 host.
    public static func host(_ input: String) throws -> String {
        try validatedAddress(input).host
    }

    /// Returns the validated local-control endpoint without accepting user info, paths, queries, or fragments.
    public static func controlURL(_ input: String) throws -> URL {
        guard let url = URL(string: try validatedAddress(input).baseAddress + "/tdkcgi") else {
            throw ValidationError.invalid
        }
        return url
    }

    private struct ValidatedAddress {
        let scheme: String
        let host: String
        let port: Int?

        var baseAddress: String {
            "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
        }
    }

    /// This parser intentionally does not use URL hostname normalization: alternate
    /// integer, octal, hexadecimal, and percent-encoded IPv4 forms are ambiguous.
    private static func validatedAddress(_ input: String) throws -> ValidatedAddress {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.invalid }

        let scheme: String
        var authority: Substring
        if let separator = trimmed.range(of: "://") {
            scheme = String(trimmed[..<separator.lowerBound]).lowercased()
            authority = trimmed[separator.upperBound...]
        } else {
            scheme = "http"
            authority = trimmed[...]
        }
        guard scheme == "http" || scheme == "https" else { throw ValidationError.invalid }

        if let slash = authority.firstIndex(of: "/") {
            guard slash == authority.index(before: authority.endIndex) else {
                throw ValidationError.invalid
            }
            authority = authority[..<slash]
        }
        guard !authority.isEmpty,
              !authority.contains("@"),
              !authority.contains("?"),
              !authority.contains("#") else {
            throw ValidationError.invalid
        }

        let hostAndPort = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard hostAndPort.count == 1 || hostAndPort.count == 2 else { throw ValidationError.invalid }
        let host = String(hostAndPort[0])
        guard isCanonicalPrivateOrLocalIPv4(host) else { throw ValidationError.invalid }

        var port: Int?
        if hostAndPort.count == 2 {
            let rawPort = hostAndPort[1]
            guard !rawPort.isEmpty,
                  rawPort.allSatisfy({ $0.asciiValue.map { (48...57).contains($0) } ?? false }),
                  rawPort.count == 1 || rawPort.first != "0",
                  let parsedPort = Int(rawPort),
                  (1...65_535).contains(parsedPort) else {
                throw ValidationError.invalid
            }
            port = parsedPort
        }
        return ValidatedAddress(scheme: scheme, host: host, port: port)
    }

    private static func isCanonicalPrivateOrLocalIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }

        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty,
                  part.count == 1 || part.first != "0",
                  part.allSatisfy({ $0.asciiValue.map { (48...57).contains($0) } ?? false }),
                  let value = Int(part),
                  (0...255).contains(value) else { return nil }
            return value
        }
        guard octets.count == 4 else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
            || octets[0] == 127
    }
}
