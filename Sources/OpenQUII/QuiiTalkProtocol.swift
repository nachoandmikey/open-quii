import Foundation
import CryptoKit

public struct QuiiTalkTimestamp: Equatable, Sendable {
    public let unixSeconds: Int64
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int
    public let milliseconds: Int

    public init(
        unixSeconds: Int64,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        milliseconds: Int
    ) {
        self.unixSeconds = unixSeconds
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.milliseconds = milliseconds
    }

    public init(date: Date) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        unixSeconds = Int64(date.timeIntervalSince1970)
        year = components.year ?? 2000
        month = components.month ?? 1
        day = components.day ?? 1
        hour = components.hour ?? 0
        minute = components.minute ?? 0
        second = components.second ?? 0
        milliseconds = components.nanosecond.map { $0 / 1_000_000 } ?? 0
    }

    public var packedDHTIME: UInt32 {
        let compactYear = UInt32(clamping: year - 2000) & 0x3f
        return (compactYear << 26)
            | ((UInt32(clamping: month) & 0x0f) << 22)
            | ((UInt32(clamping: day) & 0x1f) << 17)
            | ((UInt32(clamping: hour) & 0x1f) << 12)
            | ((UInt32(clamping: minute) & 0x3f) << 6)
            | (UInt32(clamping: second) & 0x3f)
    }
}

public enum QuiiTalkProtocolError: LocalizedError, Equatable {
    case invalidPCMChunkSize
    case invalidPayloadSize
    case invalidTimestamp
    case invalidDataEncodeKey
    case invalidAuthenticationMetadata
    case invalidSetupResponse
    case unsupportedSecurityMode
    case invalidControlResponse
    case loginRejected(UInt8)
    case unsupportedCodec

    public var errorDescription: String? {
        switch self {
        case .invalidPCMChunkSize: return "The microphone produced an unexpected audio chunk."
        case .invalidPayloadSize: return "The talk audio frame has an invalid size."
        case .invalidTimestamp: return "The talk audio frame has an invalid timestamp."
        case .invalidDataEncodeKey: return "The monitor talk encryption key is invalid."
        case .invalidAuthenticationMetadata: return "Complete explicit talk credentials are required."
        case .invalidSetupResponse: return "The monitor rejected the talk setup request."
        case .unsupportedSecurityMode: return "The monitor selected an unsupported talk security mode."
        case .invalidControlResponse: return "The monitor returned an invalid authenticated talk response."
        case .loginRejected(let result): return "The monitor rejected talk authentication (result \(result))."
        case .unsupportedCodec: return "The monitor does not advertise the required PCMA talk codec."
        }
    }
}

public enum QuiiG711ALaw {
    private static let segmentEnds: [Int32] = [
        0x1f, 0x3f, 0x7f, 0xff, 0x1ff, 0x3ff, 0x7ff, 0xfff,
    ]

    public static func encode(sample: Int16) -> UInt8 {
        var value = Int32(sample)
        let mask: UInt8
        if value >= 0 {
            mask = 0xd5
        } else {
            mask = 0x55
            value = -value - 1
        }
        value = min(value >> 3, 0x0fff)
        let segment = segmentEnds.firstIndex(where: { value <= $0 }) ?? 8
        guard segment < 8 else { return 0x7f ^ mask }
        let quantization: Int32 = segment < 2
            ? (value >> 1) & 0x0f
            : (value >> Int32(segment)) & 0x0f
        return UInt8((segment << 4) | Int(quantization)) ^ mask
    }

    public static func encodePCM16LE(_ pcm: Data) throws -> Data {
        guard pcm.count.isMultiple(of: 2) else {
            throw QuiiTalkProtocolError.invalidPCMChunkSize
        }
        var encoded = Data(capacity: pcm.count / 2)
        var index = pcm.startIndex
        while index < pcm.endIndex {
            let low = UInt16(pcm[index])
            let high = UInt16(pcm[pcm.index(after: index)]) << 8
            encoded.append(encode(sample: Int16(bitPattern: low | high)))
            index = pcm.index(index, offsetBy: 2)
        }
        return encoded
    }

    public static func decodePCMA(_ pcma: Data) -> Data {
        var pcm = Data(capacity: pcma.count * 2)
        for byte in pcma {
            let value = byte ^ 0x55
            var magnitude = Int16(value & 0x0f) << 4
            let segment = Int((value & 0x70) >> 4)
            switch segment {
            case 0:
                magnitude += 8
            case 1:
                magnitude += 0x108
            default:
                magnitude += 0x108
                magnitude <<= Int16(segment - 1)
            }
            let sample: Int16 = value & 0x80 == 0 ? -magnitude : magnitude
            var littleEndian = sample.littleEndian
            Swift.withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
        }
        return pcm
    }
}

/// Accumulates two fixed-size capture callbacks. Each callback is
/// 480 bytes of PCM16LE (240 samples / 30 ms). A 480-byte PCMA payload is
/// emitted only after two complete callbacks (60 ms).
public struct QuiiTalkAudioAccumulator: Sendable {
    public private(set) var encoded = Data()

    public mutating func appendPCM16Callback(_ pcm: Data) throws -> Data? {
        guard pcm.count == 480 else {
            throw QuiiTalkProtocolError.invalidPCMChunkSize
        }
        encoded.append(try QuiiG711ALaw.encodePCM16LE(pcm))
        guard encoded.count >= 480 else { return nil }
        let payload = Data(encoded.prefix(480))
        encoded.removeFirst(480)
        return payload
    }

    public mutating func reset() {
        encoded.removeAll(keepingCapacity: true)
    }
}

public enum QuiiTalkWireProtocol {
    public static let setupType: UInt8 = 0xa9
    public static let openType: UInt8 = 0x0b
    public static let requestAudioType: UInt8 = 0x0c
    public static let startTalkType: UInt8 = 0x0d
    public static let mediaType: UInt8 = 0xa2
    public static let recordHeaderSize = 32
    public static let frameHeaderSize = 20
    public static let payloadSize = 480
    public static let frameSize = frameHeaderSize + payloadSize
    public static let recordSize = recordHeaderSize + frameSize

    public static func setupRequest() -> Data {
        var request = Data(count: recordHeaderSize)
        request[0] = setupType
        // The talk endpoint requires the requested encrypted security mode here.
        // A zero byte is accepted by the video path but leaves talk unanswered.
        request[9] = 2
        return request
    }

    public static func validateSetupResponse(_ response: Data) throws {
        guard response.count == recordHeaderSize, response[0] == setupType, response[9] == 0 else {
            throw QuiiTalkProtocolError.invalidSetupResponse
        }
        guard response[10] == 2, response[11] == 1 else {
            throw QuiiTalkProtocolError.unsupportedSecurityMode
        }
    }

    public static func authenticatedControlRequest(
        type: UInt8,
        channel: UInt16 = 1,
        mode: UInt8 = 1,
        codecSelector: UInt8 = 0,
        frequency: UInt16 = 8_000,
        inner: Bool = true,
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970),
        dataEncodeKey: Data
    ) throws -> Data {
        guard type == requestAudioType || type == startTalkType,
              channel > 0,
              dataEncodeKey.count == 32 else {
            if dataEncodeKey.count != 32 { throw QuiiTalkProtocolError.invalidDataEncodeKey }
            throw QuiiTalkProtocolError.invalidControlResponse
        }

        var header = Data(count: recordHeaderSize)
        header[0] = type
        header.writeLittleEndian(timestamp, at: 1)
        header.writeLittleEndian(UInt16(SHA256.byteCount), at: 9)
        header.writeLittleEndian(channel, at: 11)
        header[13] = mode
        if type == requestAudioType {
            header[14] = codecSelector
            header.writeLittleEndian(frequency, at: 15)
        }
        header[17] = inner ? 1 : 0
        return try authenticatedControl(header: header, dataEncodeKey: dataEncodeKey)
    }

    public static func validateOpenResponse(_ response: Data, dataEncodeKey: Data) throws {
        let header = try validatedControlHeader(response, expectedType: openType, dataEncodeKey: dataEncodeKey)
        let result = header[11]
        guard result == 0 else { throw QuiiTalkProtocolError.loginRejected(result) }
        let codecMask = UInt16(header[12]) | (UInt16(header[13]) << 8)
        guard codecMask & 1 == 1 else { throw QuiiTalkProtocolError.unsupportedCodec }
        // A zero reserved/mode byte is valid after authenticated acceptance.
        // Authentication and integrity are already proven by result + SHA-256.
    }

    public static func validatePlayResponse(
        _ response: Data,
        expectedType: UInt8,
        dataEncodeKey: Data
    ) throws {
        let header = try validatedControlHeader(response, expectedType: expectedType, dataEncodeKey: dataEncodeKey)
        let result = header[11]
        guard result == 0 else { throw QuiiTalkProtocolError.loginRejected(result) }
        guard header[12] == 1 else { throw QuiiTalkProtocolError.invalidControlResponse }
    }

    private static func authenticatedControl(header: Data, dataEncodeKey: Data) throws -> Data {
        guard header.count == recordHeaderSize else { throw QuiiTalkProtocolError.invalidControlResponse }
        let digest = Data(SHA256.hash(data: header))
        return try QuiiAES256CBC.encrypt(header, key: dataEncodeKey)
            + QuiiAES256CBC.encrypt(digest, key: dataEncodeKey)
    }

    private static func validatedControlHeader(
        _ response: Data,
        expectedType: UInt8,
        dataEncodeKey: Data
    ) throws -> Data {
        guard dataEncodeKey.count == 32 else { throw QuiiTalkProtocolError.invalidDataEncodeKey }
        guard response.count == recordHeaderSize + SHA256.byteCount else {
            throw QuiiTalkProtocolError.invalidControlResponse
        }
        let header = try QuiiAES256CBC.decrypt(Data(response.prefix(recordHeaderSize)), key: dataEncodeKey)
        let digest = try QuiiAES256CBC.decrypt(Data(response.dropFirst(recordHeaderSize)), key: dataEncodeKey)
        guard header[0] == expectedType,
              UInt16(header[9]) | (UInt16(header[10]) << 8) == UInt16(SHA256.byteCount),
              digest == Data(SHA256.hash(data: header)) else {
            throw QuiiTalkProtocolError.invalidControlResponse
        }
        return header
    }

    public static func openRequest(
        username: String,
        passwordDigest: String,
        compactOEMID: String,
        clientID: String,
        channel: UInt16 = 1,
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970),
        dataEncodeKey: Data
    ) throws -> Data {
        guard dataEncodeKey.count == 32 else {
            throw QuiiTalkProtocolError.invalidDataEncodeKey
        }
        guard channel > 0,
              !username.isEmpty,
              !passwordDigest.isEmpty,
              !compactOEMID.isEmpty,
              !clientID.isEmpty,
              [username, passwordDigest, compactOEMID, clientID].allSatisfy({ $0.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7e } }) else {
            throw QuiiTalkProtocolError.invalidAuthenticationMetadata
        }

        var plain = Data("\(username)&&\(passwordDigest)".utf8)
        plain.append(0)
        plain.append(Data(compactOEMID.utf8))
        plain.append(0)
        plain.append(Data("clientid=\(clientID)".utf8))
        plain.append(0)

        let digestSize = SHA256.byteCount
        let encryptedLength = ((plain.count + digestSize + 15) / 16) * 16
        guard plain.count <= Int(UInt16.max), encryptedLength <= Int(UInt16.max) else {
            throw QuiiTalkProtocolError.invalidAuthenticationMetadata
        }

        var header = Data(count: recordHeaderSize)
        header[0] = openType
        header.writeLittleEndian(timestamp, at: 1)
        header.writeLittleEndian(UInt16(encryptedLength), at: 9)
        header.writeLittleEndian(UInt16(plain.count), at: 11)
        header.writeLittleEndian(channel, at: 13)

        var body = plain
        body.append(Data(SHA256.hash(data: header + plain)))
        body.append(Data(count: encryptedLength - body.count))
        return try QuiiAES256CBC.encrypt(header, key: dataEncodeKey)
            + QuiiAES256CBC.encrypt(body, key: dataEncodeKey)
    }

    public static func cleartextAP2Record(
        pcmaPayload: Data,
        timestamp: QuiiTalkTimestamp,
        encryptedPrefixLength: UInt16 = 32,
        opaqueByte: UInt8 = 0
    ) throws -> Data {
        guard pcmaPayload.count == payloadSize else {
            throw QuiiTalkProtocolError.invalidPayloadSize
        }
        guard (2000...2063).contains(timestamp.year),
              (1...12).contains(timestamp.month),
              (1...31).contains(timestamp.day),
              (0...23).contains(timestamp.hour),
              (0...59).contains(timestamp.minute),
              (0...59).contains(timestamp.second),
              (0...999).contains(timestamp.milliseconds) else {
            throw QuiiTalkProtocolError.invalidTimestamp
        }

        var outer = Data(count: recordHeaderSize)
        outer[0] = mediaType
        outer.writeLittleEndian(timestamp.unixSeconds, at: 1)
        outer.writeLittleEndian(encryptedPrefixLength, at: 9)
        outer.writeLittleEndian(UInt32(frameSize), at: 11)
        outer[15] = opaqueByte

        var frame = Data(count: frameHeaderSize)
        frame[0] = 0
        frame[1] = 0
        frame[2] = 1
        frame[3] = 0xe3
        frame.writeLittleEndian(UInt32(payloadSize), at: 4)
        frame.writeLittleEndian(timestamp.packedDHTIME, at: 8)
        frame.writeLittleEndian(UInt16(timestamp.milliseconds), at: 12)
        frame[14] = 4       // Native codec 4: G.711 A-law / PCMA.
        frame[15] = 1       // Mono.
        frame.writeLittleEndian(UInt16(8_000), at: 16)
        frame.append(pcmaPayload)
        return outer + frame
    }

    public static func encryptedAP2Record(
        pcmaPayload: Data,
        timestamp: QuiiTalkTimestamp,
        dataEncodeKey: Data,
        opaqueByte: UInt8 = 0
    ) throws -> Data {
        guard dataEncodeKey.count == 32 else {
            throw QuiiTalkProtocolError.invalidDataEncodeKey
        }
        let clear = try cleartextAP2Record(
            pcmaPayload: pcmaPayload,
            timestamp: timestamp,
            encryptedPrefixLength: 32,
            opaqueByte: opaqueByte
        )
        let encryptedOuter = try QuiiAES256CBC.encrypt(Data(clear[0..<32]), key: dataEncodeKey)
        let encryptedFramePrefix = try QuiiAES256CBC.encrypt(Data(clear[32..<64]), key: dataEncodeKey)
        return encryptedOuter + encryptedFramePrefix + clear.dropFirst(64)
    }
}

private extension Data {
    mutating func writeLittleEndian<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { bytes in
            replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }
}
