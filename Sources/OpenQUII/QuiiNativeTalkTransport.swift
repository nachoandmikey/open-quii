@preconcurrency import Foundation
@preconcurrency import Network

private enum QuiiTalkTransportError: LocalizedError {
    case notReady
    case closed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notReady: return "The talk connection is not ready."
        case .closed: return "The monitor closed the talk connection."
        case .invalidResponse: return "The monitor returned an incomplete talk response."
        }
    }
}

private final class OneShotGate: @unchecked Sendable {
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

/// Dedicated talk-only connection. It does not own or reference camera or door-control state.
public final class QuiiNativeTalkTransport: IntercomTalkTransport, @unchecked Sendable {
    private let credentials: QuiiTalkCredentials
    private let port: UInt16
    private let queue = DispatchQueue(label: "OpenQUII.QuiiNativeTalkTransport")
    private var connection: NWConnection?
    private var isReady = false
    private var accumulator = QuiiTalkAudioAccumulator()
    private var receiveParser: QuiiRecordParser

    public init(
        credentials: QuiiTalkCredentials,
        port: UInt16 = QuiiNativeVideoProtocol.defaultPort
    ) throws {
        self.credentials = credentials
        self.port = port
        self.receiveParser = try QuiiRecordParser(dataEncodeKey: credentials.video.dataEncodeKey)
    }

    public func connect(
        onState: @escaping @Sendable (String) -> Void,
        onAudio: @escaping @Sendable (QuiiNativeAudioFrame) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws {
        let parameters = NWParameters.tcp
        let connection = NWConnection(
            host: NWEndpoint.Host(credentials.video.host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        try await onQueue {
            self.isReady = false
            self.accumulator.reset()
            self.receiveParser.reset()
            self.connection?.cancel()
            self.connection = connection
        }
        onState("Connecting to monitor…")
        try await startAndWaitUntilReady(connection)
        try Task.checkCancellation()

        onState("Authenticating audio…")
        try await send(QuiiTalkWireProtocol.setupRequest(), over: connection)
        let setup = try await receiveExactly(QuiiTalkWireProtocol.recordHeaderSize, from: connection)
        try QuiiTalkWireProtocol.validateSetupResponse(setup)

        let open = try QuiiTalkWireProtocol.openRequest(
            username: "adminapp2",
            passwordDigest: credentials.video.passwordDigest,
            compactOEMID: credentials.compactOEMID,
            clientID: credentials.clientID,
            channel: credentials.channel,
            dataEncodeKey: credentials.video.dataEncodeKey
        )
        try await send(open, over: connection)
        let openResponse = try await receiveExactly(64, from: connection)
        try QuiiTalkWireProtocol.validateOpenResponse(
            openResponse,
            dataEncodeKey: credentials.video.dataEncodeKey
        )

        onState("Requesting entrance audio…")
        let requestAudio = try QuiiTalkWireProtocol.authenticatedControlRequest(
            type: QuiiTalkWireProtocol.requestAudioType,
            channel: credentials.channel,
            dataEncodeKey: credentials.video.dataEncodeKey
        )
        try await send(requestAudio, over: connection)
        try QuiiTalkWireProtocol.validatePlayResponse(
            try await receiveExactly(64, from: connection),
            expectedType: QuiiTalkWireProtocol.requestAudioType,
            dataEncodeKey: credentials.video.dataEncodeKey
        )

        onState("Starting two-way audio…")
        let startTalk = try QuiiTalkWireProtocol.authenticatedControlRequest(
            type: QuiiTalkWireProtocol.startTalkType,
            channel: credentials.channel,
            dataEncodeKey: credentials.video.dataEncodeKey
        )
        try await send(startTalk, over: connection)
        try QuiiTalkWireProtocol.validatePlayResponse(
            try await receiveExactly(64, from: connection),
            expectedType: QuiiTalkWireProtocol.startTalkType,
            dataEncodeKey: credentials.video.dataEncodeKey
        )

        try await onQueue {
            guard self.connection === connection else { throw QuiiTalkTransportError.closed }
            self.isReady = true
            self.accumulator.reset()
            self.receiveParser.reset()
        }
        receiveRecords(from: connection, onAudio: onAudio, onFailure: onFailure)
    }

    public func sendPCM16Callback(_ pcm: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self,
                      self.isReady,
                      let connection = self.connection else {
                    continuation.resume(throwing: QuiiTalkTransportError.notReady)
                    return
                }
                do {
                    guard let payload = try self.accumulator.appendPCM16Callback(pcm) else {
                        continuation.resume()
                        return
                    }
                    let record = try QuiiTalkWireProtocol.encryptedAP2Record(
                        pcmaPayload: payload,
                        timestamp: QuiiTalkTimestamp(date: Date()),
                        dataEncodeKey: self.credentials.video.dataEncodeKey
                    )
                    connection.send(content: record, completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    })
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.isReady = false
                self?.accumulator.reset()
                self?.receiveParser.reset()
                // Keep the handler installed until cancellation is delivered so an
                // in-flight `startAndWaitUntilReady` continuation cannot be stranded.
                self?.connection?.cancel()
                self?.connection = nil
                continuation.resume()
            }
        }
    }

    private func startAndWaitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = OneShotGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard gate.claim() else { return }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveExactly(_ count: Int, from connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let chunk = try await receiveChunk(maximumLength: remaining, from: connection)
            guard !chunk.isEmpty else { throw QuiiTalkTransportError.closed }
            result.append(chunk)
        }
        guard result.count == count else { throw QuiiTalkTransportError.invalidResponse }
        return result
    }

    private func receiveChunk(maximumLength: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: QuiiTalkTransportError.closed)
                } else {
                    continuation.resume(throwing: QuiiTalkTransportError.invalidResponse)
                }
            }
        }
    }

    private func receiveRecords(
        from connection: NWConnection,
        onAudio: @escaping @Sendable (QuiiNativeAudioFrame) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self,
                  self.connection === connection,
                  self.isReady else { return }

            if let error {
                self.failReceive(error, onFailure: onFailure)
                return
            }

            if let data, !data.isEmpty {
                do {
                    for sample in try self.receiveParser.appendMedia(data) {
                        if case .audio(let frame) = sample {
                            onAudio(frame)
                        }
                    }
                } catch {
                    self.failReceive(error, onFailure: onFailure)
                    return
                }
            }

            if isComplete {
                self.failReceive(QuiiTalkTransportError.closed, onFailure: onFailure)
            } else {
                self.receiveRecords(from: connection, onAudio: onAudio, onFailure: onFailure)
            }
        }
    }

    private func failReceive(
        _ error: Error,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        guard isReady else { return }
        isReady = false
        receiveParser.reset()
        onFailure(error)
    }

    private func onQueue(_ operation: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try operation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
