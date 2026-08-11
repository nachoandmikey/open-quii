import Foundation
import Network
import XCTest
@testable import OpenQUII

final class LocalQualvisionClientTests: XCTestCase {
    func testSharedAddressContract() throws {
        let fixtures: AddressFixtures = try FixtureLoader.load("addresses.json")
        for fixture in fixtures.cases {
            if let canonical = fixture.canonical {
                XCTAssertEqual(
                    try LocalQualvisionClient.canonicalMonitorAddress(fixture.input),
                    canonical,
                    fixture.id
                )
            } else {
                XCTAssertThrowsError(
                    try LocalQualvisionClient.canonicalMonitorAddress(fixture.input),
                    fixture.id
                )
            }
        }
    }

    func testSharedControlRequestContract() throws {
        let fixtures: ControlFixtures = try FixtureLoader.load("control_requests.json")
        let status = try LocalQualvisionClient.makeReadOnlyRequest(
            monitorAddress: "192.168.50.10",
            verificationCode: fixtures.verificationDigest,
            command: fixtures.status.command
        )
        XCTAssertEqual(status.httpMethod, fixtures.method)
        XCTAssertEqual(status.url?.path, fixtures.path)
        XCTAssertEqual(status.value(forHTTPHeaderField: "Content-Type"), fixtures.contentType)
        XCTAssertEqual(String(decoding: try XCTUnwrap(status.httpBody), as: UTF8.self), fixtures.status.expectedXml)

        for fixture in fixtures.controls {
            let unlockCredential: LocalQualvisionClient.UnlockCredential
            switch fixture.unlockCredential.kind {
            case "plaintext":
                unlockCredential = .plaintext(fixture.unlockCredential.value)
            case "sha256_digest":
                unlockCredential = .sha256Digest(fixture.unlockCredential.value)
            default:
                XCTFail("Unknown unlock credential kind: \(fixture.unlockCredential.kind)")
                continue
            }
            let request = try LocalQualvisionClient.makeOpenDoorRequest(
                monitorAddress: "192.168.50.10",
                verificationCode: fixtures.verificationDigest,
                unlockCredential: unlockCredential,
                door: fixture.door,
                lockNumber: fixture.lock
            )
            XCTAssertEqual(
                String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self),
                fixture.expectedXml,
                fixture.id
            )
        }
    }

    func testDoor1Lock1RequestHasExpectedLocalShape() throws {
        let headerDigest = String(repeating: "a", count: 64)
        let unlockDigest = String(repeating: "b", count: 64)
        let request = try LocalQualvisionClient.makeOpenDoorRequest(
            monitorAddress: "192.168.50.10",
            verificationCode: headerDigest,
            unlockCredential: .sha256Digest(unlockDigest),
            door: 1,
            lockNumber: 1
        )
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.50.10/tdkcgi")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("<command>set.device.opendoor</command>"))
        XCTAssertTrue(body.contains("<door>1</door>"))
        XCTAssertTrue(body.contains("<locknumber>1</locknumber>"))
        XCTAssertFalse(body.contains("<password></password>"))
        XCTAssertEqual(body.components(separatedBy: "<password>\(headerDigest)</password>").count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: "<password>\(unlockDigest)</password>").count - 1, 1)
    }

    func testDoorControlRejectsNonLocalHostnameBeforeBuildingRequest() {
        XCTAssertThrowsError(
            try LocalQualvisionClient.makeOpenDoorRequest(
                monitorAddress: "example.ts.net:10080",
                verificationCode: String(repeating: "d", count: 64),
                unlockPassword: String(repeating: "e", count: 64),
                door: 1
            )
        )
    }

    func testCanonicalAddressPreservesPrivatePortAndRemovesTrailingSlash() throws {
        XCTAssertEqual(
            try LocalQualvisionClient.canonicalMonitorAddress(" https://192.168.50.10:8443/ "),
            "https://192.168.50.10:8443"
        )
    }

    func testDoorControlRejectsExternalAndCredentialBearingURLs() {
        let invalid = [
            "https://example.com",
            "http://user:pass@192.168.50.10",
            "file:///tmp/x",
            "http://192.168.50.10/path",
            "http://192.168.50.10?query=1",
            "http://192.168.50.10#fragment"
        ]
        for address in invalid {
            XCTAssertThrowsError(try LocalQualvisionClient.canonicalMonitorAddress(address), address)
        }
    }

    func testDoor2Lock1RequestHasIndependentTarget() throws {
        let request = try LocalQualvisionClient.makeOpenDoorRequest(
            monitorAddress: "192.168.50.10",
            verificationCode: String(repeating: "b", count: 64),
            unlockCredential: .sha256Digest(String(repeating: "c", count: 64)),
            door: 2,
            lockNumber: 1
        )
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("<door>2</door>"))
        XCTAssertTrue(body.contains("<locknumber>1</locknumber>"))
        XCTAssertFalse(body.contains("<password></password>"))
        XCTAssertEqual(body.components(separatedBy: "<password>\(String(repeating: "b", count: 64))</password>").count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: "<password>\(String(repeating: "c", count: 64))</password>").count - 1, 1)
        XCTAssertFalse(body.contains("<door>1</door>"))
    }

    func testPlaintextUnlockPasswordIsEncodedSeparatelyForAbility24() throws {
        let headerDigest = String(repeating: "a", count: 64)
        let request = try LocalQualvisionClient.makeOpenDoorRequest(
            monitorAddress: "192.168.50.10",
            verificationCode: headerDigest,
            unlockPassword: "separate-unlock-password",
            door: 1
        )
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(body.components(separatedBy: "<password>\(headerDigest)</password>").count - 1, 1)
        XCTAssertTrue(body.contains("<password>bc77eabb798bc88759b8a9be7f386076b53d177872e1a1997b9459dc288da9bf</password>"))
        XCTAssertFalse(body.contains("<password>separate-unlock-password</password>"))
    }

    func testHexShapedPlaintextRequiresExplicitCredentialKind() throws {
        let explicitRequest = try LocalQualvisionClient.makeOpenDoorRequest(
            monitorAddress: "192.168.50.10",
            verificationCode: String(repeating: "a", count: 64),
            unlockCredential: .plaintext(String(repeating: "b", count: 64)),
            door: 1
        )
        let body = String(decoding: try XCTUnwrap(explicitRequest.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("<password>a0fab1377f49a759b57f63318262ebe89fabfc990e8e93ceac2984561482b9d4</password>"))

        XCTAssertThrowsError(
            try LocalQualvisionClient.makeOpenDoorRequest(
                monitorAddress: "192.168.50.10",
                verificationCode: String(repeating: "a", count: 64),
                unlockPassword: String(repeating: "b", count: 64),
                door: 1
            )
        )
    }

    func testProtocolResponseMustBeWellFormedXML() throws {
        let malformed = Data("<envelope><body><result>0</result></body>".utf8)
        XCTAssertThrowsError(try LocalQualvisionClient.protocolCode(from: malformed))

        let nestedCode = Data("<envelope><body><result><code>0</code></result></body></envelope>".utf8)
        XCTAssertThrowsError(try LocalQualvisionClient.protocolCode(from: nestedCode))
    }

    func testProtocolResponseParsesNamespacedErrorBeforeResult() throws {
        let response = Data("<e:envelope xmlns:e=\"urn:fake\"><e:result>0</e:result><e:error>7</e:error></e:envelope>".utf8)
        XCTAssertEqual(try LocalQualvisionClient.protocolCode(from: response), "7")
    }

    func testReadOnlyControlPathProbeCannotUnlock() throws {
        let digest = String(repeating: "e", count: 64)
        let request = try LocalQualvisionClient.makeReadOnlyRequest(
            monitorAddress: "192.168.50.10:10080",
            verificationCode: digest,
            command: "get.device.status"
        )
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.50.10:10080/tdkcgi")
        XCTAssertEqual(request.timeoutInterval, 8)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Connection"), "close")
        XCTAssertTrue(body.contains("<command>get.device.status</command>"))
        XCTAssertFalse(body.contains("opendoor"))
        XCTAssertFalse(body.contains("<door>"))
        XCTAssertEqual(body.components(separatedBy: "<password>\(digest)</password>").count - 1, 1)
    }

    func testReadOnlyControlPathProbeRejectsActuatingCommand() {
        XCTAssertThrowsError(
            try LocalQualvisionClient.makeReadOnlyRequest(
                monitorAddress: "192.168.50.10",
                verificationCode: String(repeating: "f", count: 64),
                command: "set.device.opendoor"
            )
        )
    }

    func testOpenDoorRequestRejectsMissingVerificationDigest() {
        XCTAssertThrowsError(
            try LocalQualvisionClient.makeOpenDoorRequest(
                monitorAddress: "192.168.50.10",
                verificationCode: "not-a-device-digest",
                unlockPassword: "separate-unlock-password",
                door: 1
            )
        )
    }

    func testOpenDoorRejectsRedirectWithoutSecondPOST() async throws {
        let server = try RedirectHTTPServer()
        let port = try await server.start()
        defer { server.stop() }
        let client = LocalQualvisionClient()

        do {
            try await client.openDoor(
                monitorAddress: "127.0.0.1:\(port)",
                verificationCode: String(repeating: "a", count: 64),
                unlockCredential: .sha256Digest(String(repeating: "b", count: 64)),
                door: 1,
                lockNumber: 1
            )
            XCTFail("A redirected unlock must not succeed")
        } catch {
            // Expected: the original 307 is rejected as an invalid response.
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(server.recordedPaths(), ["/tdkcgi"])
    }

    func testOpenDoorRequestRejectsInvalidTarget() {
        let digest = String(repeating: "c", count: 64)
        XCTAssertThrowsError(
            try LocalQualvisionClient.makeOpenDoorRequest(
                monitorAddress: "192.168.50.10",
                verificationCode: digest,
                unlockPassword: "separate-unlock-password",
                door: 0
            )
        )
        XCTAssertThrowsError(
            try LocalQualvisionClient.makeOpenDoorRequest(
                monitorAddress: "192.168.50.10",
                verificationCode: digest,
                unlockPassword: "separate-unlock-password",
                door: 2,
                lockNumber: 0
            )
        )
        XCTAssertThrowsError(
            try LocalQualvisionClient.makeOpenDoorRequest(
                monitorAddress: "192.168.50.10",
                verificationCode: digest,
                unlockPassword: "separate-unlock-password",
                door: 3
            )
        )
        XCTAssertThrowsError(
            try LocalQualvisionClient.makeOpenDoorRequest(
                monitorAddress: "192.168.50.10",
                verificationCode: digest,
                unlockPassword: "separate-unlock-password",
                door: 1,
                lockNumber: 2
            )
        )
    }
}

private struct AddressFixtures: Decodable {
    let cases: [AddressFixture]
}

private struct AddressFixture: Decodable {
    let id: String
    let input: String
    let canonical: String?
}

private struct ControlFixtures: Decodable {
    let method: String
    let path: String
    let contentType: String
    let verificationDigest: String
    let status: StatusFixture
    let controls: [ControlFixture]
}

private struct StatusFixture: Decodable {
    let command: String
    let expectedXml: String
}

private struct ControlFixture: Decodable {
    let id: String
    let door: Int
    let lock: Int
    let unlockCredential: UnlockCredentialFixture
    let expectedXml: String
}

private struct UnlockCredentialFixture: Decodable {
    let kind: String
    let value: String
}

private enum FixtureLoader {
    static func load<Value: Decodable>(_ name: String) throws -> Value {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("protocol/\(name)"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Value.self, from: data)
    }
}

private final class RedirectHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "OpenQUIITests.RedirectHTTPServer")
    private let lock = NSLock()
    private var paths: [String] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let gate = TestOneShotGate()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port?.rawValue else {
                        guard gate.claim() else { return }
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                        return
                    }
                    guard gate.claim() else { return }
                    continuation.resume(returning: port)
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    func recordedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let firstLine = request.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            self.lock.lock()
            self.paths.append(path)
            self.lock.unlock()

            let port = self.listener.port?.rawValue ?? 0
            let response = "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(port)/redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

private final class TestOneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
