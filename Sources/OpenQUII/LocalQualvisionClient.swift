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

    /// Explicitly distinguishes plaintext unlock material from a precomputed digest.
    public enum UnlockCredential: Sendable, Equatable {
        case plaintext(String)
        case sha256Digest(String)

        fileprivate func encodedValue() throws -> String {
            switch self {
            case .plaintext(let value):
                let password = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !password.isEmpty else { throw ClientError.missingVerificationCode }
                return SHA256.hash(data: Data(password.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
            case .sha256Digest(let value):
                let digest = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                    throw ClientError.missingVerificationCode
                }
                return digest
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

    /// Sends exactly one request. String unlock passwords are always treated as plaintext.
    public func openDoor(
        monitorAddress: String,
        verificationCode: String,
        unlockPassword: String,
        door: Int,
        lockNumber: Int = 1
    ) async throws {
        guard !Self.isAmbiguousLegacyUnlockPassword(unlockPassword) else {
            throw ClientError.missingVerificationCode
        }
        try await openDoor(
            monitorAddress: monitorAddress,
            verificationCode: verificationCode,
            unlockCredential: .plaintext(unlockPassword),
            door: door,
            lockNumber: lockNumber
        )
    }

    /// Sends exactly one request using an explicitly typed unlock credential.
    public func openDoor(
        monitorAddress: String,
        verificationCode: String,
        unlockCredential: UnlockCredential,
        door: Int,
        lockNumber: Int = 1
    ) async throws {
        let request = try Self.makeOpenDoorRequest(
            monitorAddress: monitorAddress,
            verificationCode: verificationCode,
            unlockCredential: unlockCredential,
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
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ClientError.invalidResponse
        }
        let result = try Self.protocolCode(from: data)
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

    /// Builds a request from a plaintext unlock password.
    public static func makeOpenDoorRequest(
        monitorAddress: String,
        verificationCode: String,
        unlockPassword: String,
        door: Int,
        lockNumber: Int = 1
    ) throws -> URLRequest {
        guard !isAmbiguousLegacyUnlockPassword(unlockPassword) else {
            throw ClientError.missingVerificationCode
        }
        return try makeOpenDoorRequest(
            monitorAddress: monitorAddress,
            verificationCode: verificationCode,
            unlockCredential: .plaintext(unlockPassword),
            door: door,
            lockNumber: lockNumber
        )
    }

    /// Builds a request from an explicitly typed unlock credential.
    public static func makeOpenDoorRequest(
        monitorAddress: String,
        verificationCode: String,
        unlockCredential: UnlockCredential,
        door: Int,
        lockNumber: Int = 1
    ) throws -> URLRequest {
        guard (door == 1 || door == 2), lockNumber == 1 else { throw ClientError.invalidAddress }
        let credential = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard credential.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw ClientError.missingVerificationCode
        }
        let encodedUnlockPassword = try unlockCredential.encodedValue()

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

    private static func isAmbiguousLegacyUnlockPassword(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 64 && trimmed.allSatisfy(\.isHexDigit)
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

    static func protocolCode(from data: Data) throws -> String {
        let delegate = ProtocolResponseParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), parser.parserError == nil,
              !delegate.invalidTargetStructure,
              let code = delegate.errorCode ?? delegate.resultCode else {
            throw ClientError.invalidResponse
        }
        return code
    }
}

private final class ProtocolResponseParserDelegate: NSObject, XMLParserDelegate {
    private var activeElement: String?
    private var text = ""
    fileprivate private(set) var errorCode: String?
    fileprivate private(set) var resultCode: String?
    fileprivate private(set) var invalidTargetStructure = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if activeElement != nil {
            invalidTargetStructure = true
            return
        }
        let localName = elementName.lowercased()
        guard localName == "error" || localName == "result" else { return }
        activeElement = localName
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard activeElement != nil else { return }
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.lowercased()
        guard activeElement == localName else { return }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !code.isEmpty {
            if localName == "error", errorCode == nil { errorCode = code }
            if localName == "result", resultCode == nil { resultCode = code }
        }
        activeElement = nil
        text = ""
    }
}
