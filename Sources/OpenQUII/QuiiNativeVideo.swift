import CryptoKit
@preconcurrency import Foundation
@preconcurrency import Network
import CommonCrypto

public enum QuiiNativeVideoError: LocalizedError, Equatable {
    case invalidHost
    case invalidPasswordDigest
    case invalidDataEncodeKey
    case invalidChannelOrStream
    case invalidSetupResponse
    case unsupportedSecurityMode
    case recordTooLarge
    case malformedRecord
    case connectionClosed
    case streamTimedOut

    public var errorDescription: String? {
        switch self {
        case .invalidHost: return "The native video receiver requires a private monitor address or tailnet relay."
        case .invalidPasswordDigest: return "The monitor password digest is invalid."
        case .invalidDataEncodeKey: return "The monitor data encryption key is invalid."
        case .invalidChannelOrStream: return "The requested video channel or stream is invalid."
        case .invalidSetupResponse: return "The monitor rejected the QUII setup request."
        case .unsupportedSecurityMode: return "The monitor uses an unsupported QUII security mode."
        case .recordTooLarge: return "The monitor sent an oversized QUII record."
        case .malformedRecord: return "The monitor sent a malformed QUII record."
        case .connectionClosed: return "The monitor closed the native video connection."
        case .streamTimedOut: return "The monitor did not start the native video stream."
        }
    }
}

/// Explicit native-media credentials. This type never derives, persists, or logs credentials.
public struct QuiiNativeVideoCredentials: Equatable, Sendable {
    public let host: String
    public let passwordDigest: String
    public let dataEncodeKey: Data

    public init(host: String, passwordDigest: String, dataEncodeKey: Data) throws {
        guard Self.isPermittedHost(host) else { throw QuiiNativeVideoError.invalidHost }
        guard passwordDigest.count == 64,
              passwordDigest.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
            throw QuiiNativeVideoError.invalidPasswordDigest
        }
        guard dataEncodeKey.count == kCCKeySizeAES256 else {
            throw QuiiNativeVideoError.invalidDataEncodeKey
        }
        self.host = host
        self.passwordDigest = passwordDigest.lowercased()
        self.dataEncodeKey = dataEncodeKey
    }

    private static func isPermittedHost(_ value: String) -> Bool {
        if isPrivateIPv4(value) { return true }
        let normalized = value.lowercased()
        guard normalized.hasSuffix(".ts.net"), normalized.count <= 253 else { return false }
        return normalized.split(separator: ".").allSatisfy { label in
            !label.isEmpty
                && label.count <= 63
                && label.first != "-"
                && label.last != "-"
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func isPrivateIPv4(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4,
              let octets = Optional(pieces.compactMap { UInt8($0) }), octets.count == 4 else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}

public struct QuiiNativeVideoFrame: Equatable, Sendable {
    public let annexB: Data
    public let isKeyframe: Bool

    public init(annexB: Data, isKeyframe: Bool) {
        self.annexB = annexB
        self.isKeyframe = isKeyframe
    }
}

public struct QuiiNativeAudioFrame: Equatable, Sendable {
    public let pcm16LE: Data
    public let sampleRate: Int
    public let channels: Int

    public init(pcm16LE: Data, sampleRate: Int, channels: Int) {
        self.pcm16LE = pcm16LE
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public enum QuiiNativeMediaSample: Equatable, Sendable {
    case video(QuiiNativeVideoFrame)
    case audio(QuiiNativeAudioFrame)
}

enum QuiiAES256CBC {
    static let iv = Data(repeating: 0x30, count: kCCBlockSizeAES128)

    static func encrypt(_ input: Data, key: Data) throws -> Data {
        try crypt(input, key: key, operation: CCOperation(kCCEncrypt))
    }

    static func decrypt(_ input: Data, key: Data) throws -> Data {
        try crypt(input, key: key, operation: CCOperation(kCCDecrypt))
    }

    private static func crypt(_ input: Data, key: Data, operation: CCOperation) throws -> Data {
        guard key.count == kCCKeySizeAES256 else { throw QuiiNativeVideoError.invalidDataEncodeKey }
        guard input.count.isMultiple(of: kCCBlockSizeAES128) else { throw QuiiNativeVideoError.malformedRecord }

        var output = Data(count: input.count)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            input.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, moved == input.count else { throw QuiiNativeVideoError.malformedRecord }
        output.removeSubrange(moved..<output.count)
        return output
    }
}

public enum QuiiNativeVideoProtocol {
    public static let headerSize = 32
    public static let defaultPort: UInt16 = 34_567
    public static let maximumRecordBody = 2 * 1_024 * 1_024
    public static let setupType: UInt8 = 0xA9
    public static let playType: UInt8 = 0x01
    public static let mediaType: UInt8 = 0xA0
    public static let audioMediaType: UInt8 = 0xA2
    public static let controlTypes: Set<UInt8> = [0, 1, 5, 6, 7, 8, 9, 10, 12, 13, 14, 15, 17, 0xA4, 0xAA, 0xFE]

    public static func setupRequest() -> Data {
        var request = Data(count: headerSize)
        request[0] = setupType
        return request
    }

    public static func playRequest(
        credentials: QuiiNativeVideoCredentials,
        channel: UInt16 = 1,
        stream: UInt16 = 2,
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970)
    ) throws -> Data {
        guard channel > 0, stream > 0, stream <= 0x100 else {
            throw QuiiNativeVideoError.invalidChannelOrStream
        }

        let username = Data("adminapp2".utf8)
        let plain = username + Data([0x26, 0x26]) + Data(credentials.passwordDigest.utf8) + Data([0, 0])
        let rawLength = plain.count
        let encryptedLength = ((rawLength + SHA256.byteCount + 15) / 16) * 16
        guard encryptedLength <= Int(UInt16.max), rawLength <= Int(UInt16.max) else {
            throw QuiiNativeVideoError.malformedRecord
        }

        var header = Data(count: headerSize)
        header[0] = playType
        header.writeLittleEndian(timestamp, at: 1)
        header.writeLittleEndian(UInt16(encryptedLength), at: 9)
        header.writeLittleEndian(UInt16(rawLength), at: 11)
        header.writeLittleEndian(channel, at: 13)
        header[15] = 1
        header[16] = UInt8(stream - 1)
        header[17] = 1

        var authenticatedBody = plain
        authenticatedBody.append(Data(SHA256.hash(data: header + plain)))
        authenticatedBody.append(Data(count: encryptedLength - authenticatedBody.count))
        return try QuiiAES256CBC.encrypt(header, key: credentials.dataEncodeKey)
            + QuiiAES256CBC.encrypt(authenticatedBody, key: credentials.dataEncodeKey)
    }

    public static func validateSetupResponse(_ response: Data) throws {
        guard response.count == headerSize, response[0] == setupType, response[9] == 0 else {
            throw QuiiNativeVideoError.invalidSetupResponse
        }
        guard response[10] == 2, response[11] == 1 else {
            throw QuiiNativeVideoError.unsupportedSecurityMode
        }
    }
}

/// Incremental parser for the encrypted records following a successful SETUP/PLAY exchange.
public struct QuiiRecordParser: Sendable {
    private let key: Data
    private var buffer = Data()

    public init(dataEncodeKey: Data) throws {
        guard dataEncodeKey.count == kCCKeySizeAES256 else { throw QuiiNativeVideoError.invalidDataEncodeKey }
        key = dataEncodeKey
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    public mutating func append(_ bytes: Data) throws -> [QuiiNativeVideoFrame] {
        try appendMedia(bytes).compactMap {
            guard case .video(let frame) = $0 else { return nil }
            return frame
        }
    }

    public mutating func appendMedia(_ bytes: Data) throws -> [QuiiNativeMediaSample] {
        buffer.append(bytes)
        var samples: [QuiiNativeMediaSample] = []

        while buffer.count >= QuiiNativeVideoProtocol.headerSize {
            // Data.removeFirst can preserve a non-zero startIndex. Slice relative to
            // the current collection indices; index 0 traps on the next live record.
            let recordStart = buffer.startIndex
            let headerEnd = buffer.index(recordStart, offsetBy: QuiiNativeVideoProtocol.headerSize)
            let encryptedHeader = Data(buffer[recordStart..<headerEnd])
            let header = try QuiiAES256CBC.decrypt(encryptedHeader, key: key)
            let messageType = header[0]
            let field9 = Int(header.readUInt16LittleEndian(at: 9))
            let field11 = Int(header.readUInt16LittleEndian(at: 11))
            let bodyLength = QuiiNativeVideoProtocol.controlTypes.contains(messageType) ? field9 : field11
            guard bodyLength <= QuiiNativeVideoProtocol.maximumRecordBody else {
                throw QuiiNativeVideoError.recordTooLarge
            }
            let recordLength = QuiiNativeVideoProtocol.headerSize + bodyLength
            guard buffer.count >= recordLength else { break }
            let recordEnd = buffer.index(recordStart, offsetBy: recordLength)
            let body = Data(buffer[headerEnd..<recordEnd])
            buffer.removeSubrange(recordStart..<recordEnd)

            guard messageType == QuiiNativeVideoProtocol.mediaType
                    || messageType == QuiiNativeVideoProtocol.audioMediaType else { continue }
            guard field9 <= body.count, field9.isMultiple(of: kCCBlockSizeAES128) else {
                throw QuiiNativeVideoError.malformedRecord
            }
            let decryptedPrefix = try QuiiAES256CBC.decrypt(Data(body.prefix(field9)), key: key)
            let framePayload = decryptedPrefix + body.dropFirst(field9)
            guard framePayload.count >= 20 else { throw QuiiNativeVideoError.malformedRecord }
            let marker = Data(framePayload.prefix(4))
            if marker == Data([0, 0, 1, 0xE0]) || marker == Data([0, 0, 1, 0xE1]) {
                guard framePayload.count >= 24,
                      Data(framePayload[20..<24]) == Data([0, 0, 0, 1]) else { continue }
                samples.append(.video(QuiiNativeVideoFrame(
                    annexB: Data(framePayload.dropFirst(20)),
                    isKeyframe: marker.last == 0xE1
                )))
                continue
            }

            // Audio may arrive as an inner E3 frame in either the shared A0
            // media envelope or the dedicated A2 audio envelope.
            guard marker == Data([0, 0, 1, 0xE3]),
                  framePayload[14] == 4,
                  framePayload[15] == 1 else { continue }
            let payloadSize = Int(framePayload.readUInt32LittleEndian(at: 4))
            let sampleRate = Int(framePayload.readUInt16LittleEndian(at: 16))
            guard payloadSize > 0,
                  sampleRate == 8_000,
                  framePayload.count >= 20 + payloadSize else {
                throw QuiiNativeVideoError.malformedRecord
            }
            let pcma = Data(framePayload[20..<(20 + payloadSize)])
            samples.append(.audio(QuiiNativeAudioFrame(
                pcm16LE: QuiiG711ALaw.decodePCMA(pcma),
                sampleRate: sampleRate,
                channels: 1
            )))
        }
        return samples
    }
}

/// Receive-only Network.framework client. Its only outbound bytes are fixed SETUP and PLAY requests.
public final class QuiiNativeVideoReceiver: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (Result<QuiiNativeVideoFrame, Error>) -> Void
    public typealias AudioHandler = @Sendable (QuiiNativeAudioFrame) -> Void
    public typealias StateHandler = @Sendable (String) -> Void

    private let credentials: QuiiNativeVideoCredentials
    private let port: UInt16
    private let channel: UInt16
    private let stream: UInt16
    private let queue = DispatchQueue(label: "OpenQUII.QuiiNativeVideoReceiver")
    private var connection: NWConnection?

    public init(
        credentials: QuiiNativeVideoCredentials,
        port: UInt16 = QuiiNativeVideoProtocol.defaultPort,
        channel: UInt16 = 1,
        stream: UInt16 = 2
    ) throws {
        guard channel > 0, stream > 0, stream <= 0x100 else {
            throw QuiiNativeVideoError.invalidChannelOrStream
        }
        self.credentials = credentials
        self.port = port
        self.channel = channel
        self.stream = stream
    }

    public func start(
        onState: @escaping StateHandler = { _ in },
        onAudio: @escaping AudioHandler = { _ in },
        onFrame: @escaping FrameHandler
    ) {
        stop()
        let parameters = NWParameters.tcp
        let connection = NWConnection(
            host: NWEndpoint.Host(credentials.host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self,
                  let connection,
                  self.connection === connection else { return }
            switch state {
            case .setup:
                onState("Opening Wi-Fi connection")
            case .preparing:
                onState("Preparing Wi-Fi connection")
            case .waiting(let error):
                onState("Wi-Fi route unavailable: \(error.localizedDescription)")
            case .ready:
                onState("Authenticating with monitor")
                self.beginHandshake(connection: connection, onAudio: onAudio, onFrame: onFrame)
            case .failed(let error):
                onFrame(.failure(error))
                self.stop()
            case .cancelled:
                onState("Disconnected")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func stop() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func beginHandshake(
        connection: NWConnection,
        onAudio: @escaping AudioHandler,
        onFrame: @escaping FrameHandler
    ) {
        connection.send(content: QuiiNativeVideoProtocol.setupRequest(), completion: .contentProcessed { [weak self] error in
            guard let self, self.connection === connection else { return }
            if let error {
                onFrame(.failure(error))
                self.stop()
                return
            }
            self.receiveExactly(QuiiNativeVideoProtocol.headerSize, from: connection) { result in
                guard self.connection === connection else { return }
                do {
                    let setup = try result.get()
                    try QuiiNativeVideoProtocol.validateSetupResponse(setup)
                    let play = try QuiiNativeVideoProtocol.playRequest(
                        credentials: self.credentials,
                        channel: self.channel,
                        stream: self.stream
                    )
                    connection.send(content: play, completion: .contentProcessed { error in
                        guard self.connection === connection else { return }
                        if let error {
                            onFrame(.failure(error))
                            self.stop()
                        } else {
                            self.receiveRecords(from: connection, onAudio: onAudio, onFrame: onFrame)
                        }
                    })
                } catch {
                    onFrame(.failure(error))
                    self.stop()
                }
            }
        })
    }

    private func receiveRecords(
        from connection: NWConnection,
        onAudio: @escaping AudioHandler,
        onFrame: @escaping FrameHandler
    ) {
        do {
            let state = try VideoReceiveState(dataEncodeKey: credentials.dataEncodeKey)
            let firstFrameTimeout = DispatchWorkItem { [weak self, weak connection, state] in
                guard let self, let connection, self.connection === connection, !state.receivedFirstFrame else { return }
                onFrame(.failure(QuiiNativeVideoError.streamTimedOut))
                self.stop()
            }
            state.timeout = firstFrameTimeout
            queue.asyncAfter(deadline: .now() + 5, execute: firstFrameTimeout)
            @Sendable func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self, state] data, _, complete, error in
                    guard let self, self.connection === connection else { return }
                    do {
                        if let error { throw error }
                        if let data, !data.isEmpty {
                            for sample in try state.parser.appendMedia(data) {
                                switch sample {
                                case .video(let frame):
                                    if !state.receivedFirstFrame {
                                        state.receivedFirstFrame = true
                                        state.timeout?.cancel()
                                    }
                                    onFrame(.success(frame))
                                case .audio(let frame):
                                    onAudio(frame)
                                }
                            }
                        }
                        if complete { throw QuiiNativeVideoError.connectionClosed }
                        receiveNext()
                    } catch {
                        state.timeout?.cancel()
                        onFrame(.failure(error))
                        self.stop()
                    }
                }
            }
            receiveNext()
        } catch {
            onFrame(.failure(error))
            stop()
        }
    }

    private func receiveExactly(
        _ count: Int,
        from connection: NWConnection,
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        let state = ReceiveExactlyState(completion: completion)
        @Sendable func receiveMore() {
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: count - state.accumulated.count
            ) { data, _, complete, error in
                if let error { state.completion(.failure(error)); return }
                if let data { state.accumulated.append(data) }
                if state.accumulated.count == count {
                    state.completion(.success(state.accumulated))
                    return
                }
                if complete {
                    state.completion(.failure(QuiiNativeVideoError.connectionClosed))
                    return
                }
                receiveMore()
            }
        }
        receiveMore()
    }
}

private final class VideoReceiveState: @unchecked Sendable {
    var parser: QuiiRecordParser
    var receivedFirstFrame = false
    var timeout: DispatchWorkItem?

    init(dataEncodeKey: Data) throws {
        parser = try QuiiRecordParser(dataEncodeKey: dataEncodeKey)
    }
}

private final class ReceiveExactlyState: @unchecked Sendable {
    var accumulated = Data()
    let completion: @Sendable (Result<Data, Error>) -> Void

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
    }
}

private extension Data {
    mutating func writeLittleEndian<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }

    func readUInt16LittleEndian(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LittleEndian(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
