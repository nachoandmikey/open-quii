import CryptoKit
import Foundation

private final class DoorControlRedirectRejector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = DoorControlRedirectRejector()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// A local-only control client that sends one request per explicit open action.
///
/// Redirects are rejected and this type never retries an open request.
public struct LocalQualvisionClient: Sendable {
    public enum ClientError: LocalizedError, Equatable {
        case invalidAddress
        case missingVerificationCode
        case rejected(String)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .invalidAddress: return "The monitor address is invalid."
            case .missingVerificationCode: return "A valid monitor verification credential is required."
            case .rejected(let code): return "The monitor rejected the open request (\(code))."
            case .invalidResponse: return "The monitor returned an unreadable response."
            }
        }
    }

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 6
            configuration.timeoutIntervalForResource = 8
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Sends exactly one request. Callers must never automatically retry this operation.
    public func openDoor(
        monitorAddress: String,
        verificationCode: String,
        unlockPassword: String,
        door: Int,
        lockNumber: Int = 1
    ) async throws {
        let request = try Self.makeOpenDoorRequest(
            monitorAddress: monitorAddress,
            verificationCode: verificationCode,
            unlockPassword: unlockPassword,
            door: door,
            lockNumber: lockNumber
        )
        try await execute(request)
    }

    private func execute(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(
            for: request,
            delegate: DoorControlRedirectRejector.shared
        )
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ClientError.invalidResponse
        }
        let xml = String(decoding: data, as: UTF8.self)
        let result = Self.firstXMLValue(named: "error", in: xml)
            ?? Self.firstXMLValue(named: "result", in: xml)
        guard let result else { throw ClientError.invalidResponse }
        guard result == "0" else { throw ClientError.rejected(result) }
    }

    public static func canonicalMonitorAddress(_ monitorAddress: String) throws -> String {
        do {
            return try MonitorAddress.canonicalBaseAddress(monitorAddress)
        } catch {
            throw ClientError.invalidAddress
        }
    }

    public static func makeReadOnlyRequest(
        monitorAddress: String,
        verificationCode: String,
        command: String
    ) throws -> URLRequest {
        let allowedCommands = Set(["get.device.status"])
        guard allowedCommands.contains(command) else { throw ClientError.invalidResponse }
        return try makeRequest(
            monitorAddress: monitorAddress,
            verificationCode: verificationCode,
            command: command,
            contentXML: "<content></content>"
        )
    }

    public static func makeOpenDoorRequest(
        monitorAddress: String,
        verificationCode: String,
        unlockPassword: String,
        door: Int,
        lockNumber: Int = 1
    ) throws -> URLRequest {
        guard (door == 1 || door == 2), lockNumber == 1 else { throw ClientError.invalidAddress }
        let credential = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard credential.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw ClientError.missingVerificationCode
        }
        let encodedUnlockPassword = try encodeUnlockPassword(unlockPassword)

        // Header authentication and lock authorization are deliberately separate.
        // Ability 24 requires the content password to be SHA-256 encoded, while
        // the authenticated header continues to use the device verification digest.
        return try makeRequest(
            monitorAddress: monitorAddress,
            verificationCode: credential,
            command: "set.device.opendoor",
            contentXML: "<content><door>\(door)</door><locknumber>\(lockNumber)</locknumber><password>\(encodedUnlockPassword)</password></content>"
        )
    }

    private static func encodeUnlockPassword(_ value: String) throws -> String {
        let password = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { throw ClientError.missingVerificationCode }
        if password.count == 64, password.allSatisfy(\.isHexDigit) {
            return password.lowercased()
        }
        return SHA256.hash(data: Data(password.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func makeRequest(
        monitorAddress: String,
        verificationCode: String,
        command: String,
        contentXML: String
    ) throws -> URLRequest {
        let url: URL
        do {
            url = try MonitorAddress.controlURL(monitorAddress)
        } catch {
            throw ClientError.invalidAddress
        }

        let credential = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard credential.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw ClientError.missingVerificationCode
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><envelope><header><security>username</security><username>adminapp2</username><password>\(credential)</password><passwordencode>1</passwordencode></header><body><command>\(command)</command>\(contentXML)</body></envelope>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.timeoutInterval = 8
        request.httpBody = Data(xml.utf8)
        return request
    }

    private static func firstXMLValue(named name: String, in xml: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let expression = try? NSRegularExpression(
            pattern: "<\\s*\(escapedName)(?:\\s[^>]*)?>(.*?)<\\s*/\\s*\(escapedName)\\s*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(xml.startIndex..., in: xml)
        guard let match = expression.firstMatch(in: xml, range: range),
              let valueRange = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
