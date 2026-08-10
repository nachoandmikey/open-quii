import XCTest
@testable import OpenQUII

final class QuiiNativeVideoTests: XCTestCase {
    private let key = Data("0123456789abcdef0123456789abcdef".utf8)
    private let digest = String(repeating: "a", count: 64)

    func testTailnetRelayHostIsAcceptedButPublicHostsRemainRejected() throws {
        XCTAssertNoThrow(try QuiiNativeVideoCredentials(
            host: "example.ts.net",
            passwordDigest: digest,
            dataEncodeKey: key
        ))
        XCTAssertThrowsError(try QuiiNativeVideoCredentials(
            host: "example.com",
            passwordDigest: digest,
            dataEncodeKey: key
        ))
    }

    func testSetupIsTheOnlyPlaintextOutboundRequestAndIsFixedWidth() {
        let request = QuiiNativeVideoProtocol.setupRequest()
        XCTAssertEqual(request.count, 32)
        XCTAssertEqual(request.first, 0xA9)
        XCTAssertTrue(request.dropFirst().allSatisfy { $0 == 0 })
    }

    func testPlayRequestMatchesDeterministicEncryptedFixture() throws {
        let credentials = try QuiiNativeVideoCredentials(
            host: "192.168.50.10",
            passwordDigest: digest,
            dataEncodeKey: key
        )
        let request = try QuiiNativeVideoProtocol.playRequest(
            credentials: credentials,
            timestamp: 0x0102030405060708
        )
        let fixture = try XCTUnwrap(Data(hex: "ef76884a07216fd5ae70544e871f884ed5facee1663c4f5b1ededac8ae09f1d8dd1d06161a112a500eb6ec59659b277bb54488d514b5eb86a9f8685c6b0f365b6dfbac37bec16cdf689e2fc9001bbbbbaa31527a4832876ef8caed449998541d33ed847a7b49d670971a3ad7110a8c2a7c6d8f5920ba7e52de435a97ee0243e04ce6526bd78ab486a5c454107c833adb"))
        XCTAssertEqual(request, fixture)

        let header = try QuiiAES256CBC.decrypt(Data(request.prefix(32)), key: key)
        XCTAssertEqual(header[0], 0x01)
        XCTAssertEqual(header[15], 1)
        XCTAssertEqual(header[16], 1)
        XCTAssertEqual(header[17], 1)
    }

    func testIncrementalParserDecryptsSyntheticMediaFixture() throws {
        let record = try XCTUnwrap(Data(hex: "17c9fa9a1b9197ee4050375e4fa774cc0f68c2f70e1381c02bf26951efb19e5a3039cb60c6549e84d2ccbfc7b946f62789f9965d5d7ea2f602bafe221f2bc97f00000001658884210000000109f00000"))
        let expectedAnnexB = try XCTUnwrap(Data(hex: "000000016742001e89abcdef00000001658884210000000109f00000"))
        var parser = try QuiiRecordParser(dataEncodeKey: key)

        XCTAssertEqual(try parser.append(Data(record.prefix(17))), [])
        XCTAssertEqual(try parser.append(Data(record[17..<63])), [])
        let frames = try parser.append(Data(record.dropFirst(63)))

        XCTAssertEqual(frames, [QuiiNativeVideoFrame(annexB: expectedAnnexB, isKeyframe: true)])
    }

    func testParserHandlesConsecutiveRecordsAfterBufferConsumption() throws {
        let record = try XCTUnwrap(Data(hex: "17c9fa9a1b9197ee4050375e4fa774cc0f68c2f70e1381c02bf26951efb19e5a3039cb60c6549e84d2ccbfc7b946f62789f9965d5d7ea2f602bafe221f2bc97f00000001658884210000000109f00000"))
        let expectedAnnexB = try XCTUnwrap(Data(hex: "000000016742001e89abcdef00000001658884210000000109f00000"))
        var parser = try QuiiRecordParser(dataEncodeKey: key)

        let frames = try parser.append(record + record)

        XCTAssertEqual(frames, [
            QuiiNativeVideoFrame(annexB: expectedAnnexB, isKeyframe: true),
            QuiiNativeVideoFrame(annexB: expectedAnnexB, isKeyframe: true),
        ])
    }

    func testParserDecryptsAndDecodesIncomingAP2StreetAudio() throws {
        let pcma = Data(repeating: 0xd5, count: 480)
        let timestamp = QuiiTalkTimestamp(
            unixSeconds: 0x0102030405060708,
            year: 2026,
            month: 8,
            day: 7,
            hour: 0,
            minute: 11,
            second: 0,
            milliseconds: 0
        )
        let record = try QuiiTalkWireProtocol.encryptedAP2Record(
            pcmaPayload: pcma,
            timestamp: timestamp,
            dataEncodeKey: key
        )
        var parser = try QuiiRecordParser(dataEncodeKey: key)

        XCTAssertEqual(try parser.appendMedia(Data(record.prefix(31))), [])
        let samples = try parser.appendMedia(Data(record.dropFirst(31)))

        XCTAssertEqual(samples, [
            .audio(QuiiNativeAudioFrame(
                pcm16LE: Data((0..<480).flatMap { _ in [UInt8(0x08), UInt8(0x00)] }),
                sampleRate: 8_000,
                channels: 1
            )),
        ])
    }

    func testParserDecodesStreetAudioMultiplexedInsideA0VideoEnvelope() throws {
        let fullPCMA = Data(repeating: 0xd5, count: 480)
        let observedPayloadSize = 320
        let timestamp = QuiiTalkTimestamp(
            unixSeconds: 0x0102030405060708,
            year: 2026,
            month: 8,
            day: 7,
            hour: 0,
            minute: 11,
            second: 0,
            milliseconds: 0
        )
        let ap2Record = try QuiiTalkWireProtocol.encryptedAP2Record(
            pcmaPayload: fullPCMA,
            timestamp: timestamp,
            dataEncodeKey: key
        )
        var outerHeader = try QuiiAES256CBC.decrypt(Data(ap2Record.prefix(32)), key: key)
        outerHeader[0] = QuiiNativeVideoProtocol.mediaType
        outerHeader.replaceSubrange(11..<15, with: [0x54, 0x01, 0x00, 0x00])
        var framePrefix = try QuiiAES256CBC.decrypt(Data(ap2Record[32..<64]), key: key)
        framePrefix.replaceSubrange(4..<8, with: [0x40, 0x01, 0x00, 0x00])
        let clearPayloadRemainder = Data(ap2Record.dropFirst(64).prefix(observedPayloadSize - 12))
        let a0Record = try QuiiAES256CBC.encrypt(outerHeader, key: key)
            + QuiiAES256CBC.encrypt(framePrefix, key: key)
            + clearPayloadRemainder
        var parser = try QuiiRecordParser(dataEncodeKey: key)

        let samples = try parser.appendMedia(a0Record)

        XCTAssertEqual(samples, [
            .audio(QuiiNativeAudioFrame(
                pcm16LE: Data((0..<observedPayloadSize).flatMap { _ in [UInt8(0x08), UInt8(0x00)] }),
                sampleRate: 8_000,
                channels: 1
            )),
        ])
    }

    func testParserSkipsNonMediaControlRecord() throws {
        var header = Data(count: 32)
        header[0] = 0x01
        let record = try QuiiAES256CBC.encrypt(header, key: key)
        var parser = try QuiiRecordParser(dataEncodeKey: key)
        XCTAssertEqual(try parser.append(record), [])
    }

    func testCredentialsRejectPublicHostAndMalformedSecrets() {
        XCTAssertThrowsError(try QuiiNativeVideoCredentials(
            host: "8.8.8.8",
            passwordDigest: digest,
            dataEncodeKey: key
        )) { XCTAssertEqual($0 as? QuiiNativeVideoError, .invalidHost) }

        XCTAssertThrowsError(try QuiiNativeVideoCredentials(
            host: "192.168.50.10",
            passwordDigest: "not-a-digest",
            dataEncodeKey: key
        )) { XCTAssertEqual($0 as? QuiiNativeVideoError, .invalidPasswordDigest) }

        XCTAssertThrowsError(try QuiiNativeVideoCredentials(
            host: "192.168.50.10",
            passwordDigest: digest,
            dataEncodeKey: Data(repeating: 0, count: 31)
        )) { XCTAssertEqual($0 as? QuiiNativeVideoError, .invalidDataEncodeKey) }
    }

    func testSetupResponseRequiresSupportedEncryptionAndDigestModes() throws {
        var response = Data(count: 32)
        response[0] = 0xA9
        response[10] = 2
        response[11] = 1
        XCTAssertNoThrow(try QuiiNativeVideoProtocol.validateSetupResponse(response))
        response[11] = 0
        XCTAssertThrowsError(try QuiiNativeVideoProtocol.validateSetupResponse(response)) {
            XCTAssertEqual($0 as? QuiiNativeVideoError, .unsupportedSecurityMode)
        }
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
