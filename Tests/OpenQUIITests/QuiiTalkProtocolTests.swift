import XCTest
import CryptoKit
@testable import OpenQUII

final class QuiiTalkProtocolTests: XCTestCase {
    private let key = Data("0123456789abcdef0123456789abcdef".utf8)
    private let timestamp = QuiiTalkTimestamp(
        unixSeconds: 0x0102030405060708,
        year: 2026,
        month: 8,
        day: 6,
        hour: 21,
        minute: 7,
        second: 9,
        milliseconds: 321
    )

    func testTalkSetupMatchesSyntheticFixture() {
        let request = QuiiTalkWireProtocol.setupRequest()

        XCTAssertEqual(request.count, 32)
        XCTAssertEqual(request[0], 0xa9)
        XCTAssertEqual(request[9], 2)
        XCTAssertTrue(request.enumerated().allSatisfy { index, byte in
            index == 0 || index == 9 || byte == 0
        })
    }

    func testPCMAEncodingMatchesIndependentG711Fixture() throws {
        let samples: [Int16] = [0, 1, -1, 1_000, -1_000, .max, .min]
        var pcm = Data()
        for sample in samples {
            var little = sample.littleEndian
            Swift.withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
        }
        XCTAssertEqual(
            try QuiiG711ALaw.encodePCM16LE(pcm),
            Data([0xd5, 0xd5, 0x55, 0xfa, 0x7a, 0xaa, 0x2a])
        )
    }

    func testPCMADecodingMatchesIndependentG711Fixture() {
        XCTAssertEqual(
            QuiiG711ALaw.decodePCMA(Data([0xd5, 0x55, 0xfa, 0x7a, 0xaa, 0x2a])),
            Data(hex: "0800f8fff00310fc007e0082")
        )
    }

    func testAccumulatorEmitsOneSixtyMillisecondFrameAfterTwoCallbacks() throws {
        var accumulator = QuiiTalkAudioAccumulator()
        let silence = Data(count: 480)

        XCTAssertNil(try accumulator.appendPCM16Callback(silence))
        let payload = try XCTUnwrap(accumulator.appendPCM16Callback(silence))

        XCTAssertEqual(payload.count, 480)
        XCTAssertTrue(payload.allSatisfy { $0 == 0xd5 })
        XCTAssertTrue(accumulator.encoded.isEmpty)
    }

    func testCleartextAP2LayoutMatchesSyntheticNativeFrame() throws {
        let payload = Data(repeating: 0xd5, count: 480)
        let record = try QuiiTalkWireProtocol.cleartextAP2Record(
            pcmaPayload: payload,
            timestamp: timestamp
        )

        XCTAssertEqual(record.count, 532)
        XCTAssertEqual(record[0], 0xa2)
        XCTAssertEqual(Data(record[1..<9]), Data(hex: "0807060504030201"))
        XCTAssertEqual(Data(record[9..<11]), Data(hex: "2000"))
        XCTAssertEqual(Data(record[11..<15]), Data(hex: "f4010000"))
        XCTAssertEqual(record[15], 0)
        XCTAssertTrue(record[16..<32].allSatisfy { $0 == 0 })

        XCTAssertEqual(Data(record[32..<52]), Data(hex: "000001e3e0010000c9510d6a41010401401f0000"))
        XCTAssertEqual(Data(record[52...]), payload)
    }

    func testEncryptedAP2GoldenPrefixAndSelectiveEncryptionBoundary() throws {
        let payload = Data(repeating: 0xd5, count: 480)
        let record = try QuiiTalkWireProtocol.encryptedAP2Record(
            pcmaPayload: payload,
            timestamp: timestamp,
            dataEncodeKey: key
        )

        XCTAssertEqual(record.count, 532)
        XCTAssertEqual(
            Data(record.prefix(64)),
            Data(hex: "294269061d9ed30dcc6694e8e86dfd23fbcf102b832985b7a4523e44251f18a4e34c79fc93d616304784523bda57d2c4f6801bc2a23f693f7338494e42af8f81")
        )
        XCTAssertEqual(Data(record.dropFirst(64)), Data(repeating: 0xd5, count: 468))
    }

    func testTalkOpenRequestUsesExplicitSyntheticCredentials() throws {
        let packet = try QuiiTalkWireProtocol.openRequest(
            username: "adminapp2",
            passwordDigest: String(repeating: "a", count: 64),
            compactOEMID: "SYNTHETICOEM",
            clientID: "synthetic-client",
            timestamp: 0x0102030405060708,
            dataEncodeKey: key
        )

        XCTAssertEqual(packet.count, 192)
        let header = try QuiiAES256CBC.decrypt(Data(packet.prefix(32)), key: key)
        let body = try QuiiAES256CBC.decrypt(Data(packet.dropFirst(32)), key: key)
        XCTAssertEqual(header[0], 0x0b)
        XCTAssertEqual(Data(header[9..<11]), Data(hex: "a000"))
        XCTAssertEqual(Data(header[11..<13]), Data(hex: "7300"))
        XCTAssertEqual(Data(header[13..<15]), Data(hex: "0100"))
        XCTAssertEqual(body[74], UInt8(ascii: "a"))
        XCTAssertEqual(body[75], 0)
        XCTAssertEqual(String(decoding: body[76..<88], as: UTF8.self), "SYNTHETICOEM")
        XCTAssertEqual(body[88], 0)
        XCTAssertEqual(String(decoding: body[89..<98], as: UTF8.self), "clientid=")
        XCTAssertEqual(String(decoding: body[98..<114], as: UTF8.self), "synthetic-client")
        XCTAssertEqual(body[114], 0)
        XCTAssertTrue(body[147...].allSatisfy { $0 == 0 })
        XCTAssertEqual(
            Data(body[115..<147]),
            Data(SHA256.hash(data: header + body.prefix(115)))
        )
    }

    func testTalkPlayControlsMatchIndependentWireFixtures() throws {
        let requestAudio = try QuiiTalkWireProtocol.authenticatedControlRequest(
            type: QuiiTalkWireProtocol.requestAudioType,
            timestamp: 0x0102030405060708,
            dataEncodeKey: key
        )
        let startTalk = try QuiiTalkWireProtocol.authenticatedControlRequest(
            type: QuiiTalkWireProtocol.startTalkType,
            timestamp: 0x0102030405060708,
            dataEncodeKey: key
        )

        XCTAssertEqual(
            Data(SHA256.hash(data: requestAudio)),
            Data(hex: "440812b87fd8a95f1922ad257da46f589a2f0f36e66b28d8f4ad210f34f91d9a")
        )
        XCTAssertEqual(
            Data(SHA256.hash(data: startTalk)),
            Data(hex: "ab21b3c40e6957ae637ea14b047d44e8f8f2663e22fd8b29be788cc7ed3a45a4")
        )

        let requestHeader = try QuiiAES256CBC.decrypt(Data(requestAudio.prefix(32)), key: key)
        XCTAssertEqual(requestHeader[0], 0x0c)
        XCTAssertEqual(Data(requestHeader[9..<18]), Data(hex: "200001000100401f01"))
        XCTAssertEqual(
            try QuiiAES256CBC.decrypt(Data(requestAudio.dropFirst(32)), key: key),
            Data(SHA256.hash(data: requestHeader))
        )

        let startHeader = try QuiiAES256CBC.decrypt(Data(startTalk.prefix(32)), key: key)
        XCTAssertEqual(startHeader[0], 0x0d)
        XCTAssertEqual(Data(startHeader[9..<18]), Data(hex: "200001000100000001"))
    }

    func testValidatedOfflineOpenAndPlayResponsesReachReadyBoundary() throws {
        var openHeader = Data(count: 32)
        openHeader[0] = QuiiTalkWireProtocol.openType
        openHeader[9] = 32
        openHeader[12] = 3
        // A zero reserved/mode byte is valid after authenticated acceptance.
        openHeader[14] = 0
        let openResponse = try authenticatedResponse(openHeader)
        XCTAssertNoThrow(try QuiiTalkWireProtocol.validateOpenResponse(openResponse, dataEncodeKey: key))

        for type in [QuiiTalkWireProtocol.requestAudioType, QuiiTalkWireProtocol.startTalkType] {
            var header = Data(count: 32)
            header[0] = type
            header[9] = 32
            header[12] = 1
            let response = try authenticatedResponse(header)
            XCTAssertNoThrow(try QuiiTalkWireProtocol.validatePlayResponse(
                response,
                expectedType: type,
                dataEncodeKey: key
            ))
        }

        var corrupted = openResponse
        corrupted[63] ^= 1
        XCTAssertThrowsError(try QuiiTalkWireProtocol.validateOpenResponse(corrupted, dataEncodeKey: key))
    }

    private func authenticatedResponse(_ header: Data) throws -> Data {
        try QuiiAES256CBC.encrypt(header, key: key)
            + QuiiAES256CBC.encrypt(Data(SHA256.hash(data: header)), key: key)
    }

    func testBuilderRejectsWrongPayloadKeyAndTimestamp() {
        XCTAssertThrowsError(try QuiiTalkWireProtocol.cleartextAP2Record(
            pcmaPayload: Data(count: 479),
            timestamp: timestamp
        )) { XCTAssertEqual($0 as? QuiiTalkProtocolError, .invalidPayloadSize) }

        XCTAssertThrowsError(try QuiiTalkWireProtocol.encryptedAP2Record(
            pcmaPayload: Data(count: 480),
            timestamp: timestamp,
            dataEncodeKey: Data(count: 31)
        )) { XCTAssertEqual($0 as? QuiiTalkProtocolError, .invalidDataEncodeKey) }

        let invalid = QuiiTalkTimestamp(
            unixSeconds: 0,
            year: 1999,
            month: 1,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0,
            milliseconds: 0
        )
        XCTAssertThrowsError(try QuiiTalkWireProtocol.cleartextAP2Record(
            pcmaPayload: Data(count: 480),
            timestamp: invalid
        )) { XCTAssertEqual($0 as? QuiiTalkProtocolError, .invalidTimestamp) }
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}
