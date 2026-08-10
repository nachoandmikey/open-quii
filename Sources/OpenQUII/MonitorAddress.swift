import Foundation

/// Validation and canonicalization for monitor control endpoints.
public enum MonitorAddress {
    public enum ValidationError: Error, Equatable {
        case invalid
    }

    /// Returns an HTTP(S) base URL only when the host is a private or local IPv4 address.
    public static func canonicalBaseAddress(_ input: String) throws -> String {
        var components = try validatedComponents(input)
        components.path = ""
        guard let url = components.url else { throw ValidationError.invalid }
        return url.absoluteString
    }

    /// Returns the validated private or local IPv4 host.
    public static func host(_ input: String) throws -> String {
        guard let host = try validatedComponents(input).host else { throw ValidationError.invalid }
        return host
    }

    /// Returns the validated local-control endpoint without accepting user info, paths, queries, or fragments.
    public static func controlURL(_ input: String) throws -> URL {
        var components = try validatedComponents(input)
        components.path = "/tdkcgi"
        guard let url = components.url else { throw ValidationError.invalid }
        return url
    }

    private static func validatedComponents(_ input: String) throws -> URLComponents {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed.contains("://") ? trimmed : "http://\(trimmed)"),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              isPrivateOrLocalIPv4(host),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw ValidationError.invalid
        }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components
    }

    private static func isPrivateOrLocalIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let a = Int(parts[0]), let b = Int(parts[1]),
              let c = Int(parts[2]), let d = Int(parts[3]),
              [a, b, c, d].allSatisfy({ (0...255).contains($0) }) else { return false }
        return a == 10
            || (a == 172 && (16...31).contains(b))
            || (a == 192 && b == 168)
            || (a == 169 && b == 254)
            || a == 127
    }
}
