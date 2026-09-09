import XCTest
@preconcurrency import Network
@testable import OpenQUII

/// All sockets are explicitly bound/connected to 127.0.0.1; no device is contacted.
final class QuiiVideoReceiverDeadlineTests: XCTestCase {
    func testSilentSetupHasAnAbsoluteHandshakeDeadline() throws {
        try checkTimeout(.silent, expected: .handshakeTimedOut)
    }

    func testPartialSetupDoesNotExtendHandshakeDeadline() throws {
        try checkTimeout(.partialSetup, expected: .handshakeTimedOut)
    }

    func testCompletedHandshakeWithoutVideoTimesOut() throws {
        try checkTimeout(.noVideo, expected: .streamTimedOut)
    }

    func testEstablishedVideoStallsDespiteOngoingControlRecords() throws {
        try checkTimeout(.frameThenControl, expected: .streamStalled, expectFrame: true)
    }

    func testAudioOnlyCannotSatisfyVideoStartup() throws {
        try checkTimeout(.audioOnly, expected: .streamTimedOut)
    }

    func testEstablishedVideoStallsDespiteOngoingAudio() throws {
        try checkTimeout(.frameThenAudio, expected: .streamStalled, expectFrame: true)
    }

    func testArbitraryUnconfiguredVideoCannotExtendStartup() throws {
        let server = try VideoFixtureServer(mode: .unconfiguredVideo)
        defer { server.stop() }
        let receiver = try makeReceiver(server)
        defer { receiver.stop() }
        let failure = expectation(description: "unconfigured video still expires")
        let record = expectation(description: "wire record was delivered")
        record.assertForOverFulfill = false
        receiver.start { result in
            switch result {
            case .success: record.fulfill()
            case .failure(let error):
                XCTAssertEqual(error as? QuiiNativeVideoError, .streamTimedOut)
                failure.fulfill()
            }
        }
        wait(for: [record, failure], timeout: 2)
    }

    func testStopFromFrameCallbackSuppressesRestOfBufferedBatch() throws {
        let server = try VideoFixtureServer(mode: .batchVideo)
        defer { server.stop() }
        let receiver = try makeReceiver(server)
        let first = expectation(description: "only one buffered frame is delivered")
        first.assertForOverFulfill = true
        receiver.start { result in
            if case .success = result { first.fulfill() }
            else { XCTFail("stopped session must not fail") }
            receiver.stop()
        }
        wait(for: [first], timeout: 2)
        let drained = expectation(description: "no buffered callbacks or stale deadline")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testStopSuppressesPendingDeadline() throws {
        let server = try VideoFixtureServer(mode: .silent)
        defer { server.stop() }
        let receiver = try makeReceiver(server)
        let callback = expectation(description: "no callback after stop")
        callback.isInverted = true
        receiver.start { _ in callback.fulfill() }
        receiver.stop()
        wait(for: [callback], timeout: 0.6)
    }

    func testFailureCallbackCanStartReplacementWithoutOldCleanupStoppingIt() throws {
        let server = try VideoFixtureServer(mode: .frameThenControl)
        defer { server.stop() }
        let receiver = try makeReceiver(server)
        defer { receiver.stop() }
        let failed = expectation(description: "old session failed")
        let replacementFrame = expectation(description: "replacement frame")
        let replacementFailure = expectation(description: "replacement has its own deadline")
        receiver.start { result in
            guard case .failure = result else { return }
            failed.fulfill()
            receiver.start { replacement in
                switch replacement {
                case .success: replacementFrame.fulfill()
                case .failure(let error):
                    XCTAssertEqual(error as? QuiiNativeVideoError, .streamStalled)
                    replacementFailure.fulfill()
                }
            }
        }
        wait(for: [failed, replacementFrame, replacementFailure], timeout: 3)
    }

    func testContinuousVideoRenewsIdleDeadlineUntilExplicitStop() throws {
        let server = try VideoFixtureServer(mode: .continuousVideo)
        defer { server.stop() }
        let receiver = try makeReceiver(server)
        defer { receiver.stop() }
        let frames = expectation(description: "frames beyond original startup and idle deadlines")
        frames.expectedFulfillmentCount = 5
        frames.assertForOverFulfill = false
        let failure = expectation(description: "no timeout while video continues")
        failure.isInverted = true
        receiver.start { result in
            switch result {
            case .success: frames.fulfill()
            case .failure: failure.fulfill()
            }
        }
        wait(for: [frames], timeout: 2)
        receiver.stop()
        wait(for: [failure], timeout: 0.4)
    }

    func testRestartInvalidatesOldHandshakeTimer() throws {
        let old = try VideoFixtureServer(mode: .silent)
        let replacement = try VideoFixtureServer(mode: .continuousVideo)
        defer { old.stop(); replacement.stop() }
        let receiver = try makeReceiver(old)
        defer { receiver.stop() }
        let oldCallback = expectation(description: "old session cannot report after replacement")
        oldCallback.isInverted = true
        receiver.start { _ in oldCallback.fulfill() }
        receiver.stop()
        receiver.makeConnection = { replacement.connection() }
        let frames = expectation(description: "replacement survives old timer")
        frames.expectedFulfillmentCount = 5
        frames.assertForOverFulfill = false
        receiver.start { result in
            if case .success = result { frames.fulfill() }
            else { XCTFail("replacement unexpectedly failed") }
        }
        wait(for: [frames, oldCallback], timeout: 2)
    }

    private func makeReceiver(_ server: VideoFixtureServer) throws -> QuiiNativeVideoReceiver {
        let receiver = try QuiiNativeVideoReceiver(credentials: .init(
            host: "192.168.50.10", passwordDigest: String(repeating: "a", count: 64),
            dataEncodeKey: VideoFixtureServer.key
        ))
        receiver.handshakeTimeout = 0.3
        receiver.firstFrameTimeout = 0.3
        receiver.frameIdleTimeout = 0.3
        receiver.makeConnection = { server.connection() }
        return receiver
    }

    private func checkTimeout(
        _ mode: VideoFixtureServer.Mode,
        expected: QuiiNativeVideoError,
        expectFrame: Bool = false
    ) throws {
        let server = try VideoFixtureServer(mode: mode)
        defer { server.stop() }
        let receiver = try makeReceiver(server)
        defer { receiver.stop() }
        let failure = expectation(description: "exactly one terminal failure")
        failure.assertForOverFulfill = true
        let frame = expectation(description: "video frame")
        frame.isInverted = !expectFrame
        receiver.start { result in
            switch result {
            case .success: frame.fulfill()
            case .failure(let error):
                XCTAssertEqual(error as? QuiiNativeVideoError, expected)
                failure.fulfill()
            }
        }
        wait(for: [failure], timeout: 2)
        wait(for: [frame], timeout: expectFrame ? 0.1 : 0.2)
        // Drain cancellation and pending timer callbacks to catch double termination.
        let drained = expectation(description: "drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}

private final class VideoFixtureServer: @unchecked Sendable {
    enum Mode { case silent, partialSetup, noVideo, frameThenControl, audioOnly, frameThenAudio, continuousVideo, unconfiguredVideo, batchVideo }
    static let key = Data("0123456789abcdef0123456789abcdef".utf8)
    private let queue = DispatchQueue(label: "OpenQUII.tests.loopback")
    private let listener: NWListener
    private var peers: [NWConnection] = []
    private let mode: Mode
    private let video: Data
    private let audio: Data
    private let control: Data
    private var port: NWEndpoint.Port { listener.port! }

    init(mode: Mode) throws {
        self.mode = mode
        var header = Data(count: 32)
        header[0] = 0xA0
        // 20-byte media header followed by a synthetic Annex-B NAL.
        var payload = Data([0, 0, 1, 0xE1]) + Data(count: 16) + Data([0, 0, 0, 1, 0x67, 0x88, 0, 0, 0, 1, 0x68, 0x88, 0, 0, 0, 1, 0x65, 0x88])
        if mode == .unconfiguredVideo {
            payload = Data([0, 0, 1, 0xE1]) + Data(count: 16) + Data([0, 0, 0, 1, 0x65, 0x88])
        }
        header[11] = UInt8(payload.count)
        video = try QuiiAES256CBC.encrypt(header, key: Self.key) + payload
        header = Data(count: 32)
        header[0] = 1
        control = try QuiiAES256CBC.encrypt(header, key: Self.key)
        header[0] = 0xA2
        var audioPayload = Data(count: 20)
        audioPayload.replaceSubrange(0..<4, with: [0, 0, 1, 0xE3])
        audioPayload[4] = 1
        audioPayload[14] = 4
        audioPayload[15] = 1
        audioPayload[16] = 0x40
        audioPayload[17] = 0x1f
        audioPayload.append(0xd5)
        header[11] = UInt8(audioPayload.count)
        audio = try QuiiAES256CBC.encrypt(header, key: Self.key) + audioPayload
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] peer in
            guard let self else { peer.cancel(); return }
            self.peers.append(peer)
            peer.start(queue: self.queue)
            self.receiveSetup(peer)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, listener.port != nil else {
            listener.cancel()
            throw QuiiNativeVideoError.connectionClosed
        }
    }

    func connection() -> NWConnection {
        NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    }

    func stop() {
        queue.sync {
            listener.newConnectionHandler = nil
            listener.cancel()
            for peer in peers { peer.cancel() }
            peers.removeAll()
        }
    }

    private func receiveSetup(_ peer: NWConnection) {
        peer.receive(minimumIncompleteLength: 32, maximumLength: 32) { [weak self] data, _, _, _ in
            guard let self, let data, data.count == 32 else { return }
            XCTAssertEqual(data, QuiiNativeVideoProtocol.setupRequest())
            if self.mode == .silent { return }
            var setup = Data(count: 32)
            setup[0] = 0xA9; setup[10] = 2; setup[11] = 1
            if self.mode == .partialSetup { setup = Data(setup.prefix(8)) }
            peer.send(content: setup, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil, self.mode != .partialSetup else { return }
                peer.receive(minimumIncompleteLength: 144, maximumLength: 144) { [weak self] data, _, _, _ in
                    guard let self, data?.count == 144 else { return }
                    if self.mode == .noVideo { return }
                    self.sendTick(peer, first: true)
                }
            })
        }
    }

    private func sendTick(_ peer: NWConnection, first: Bool) {
        let bytes: Data
        switch mode {
        case .continuousVideo, .unconfiguredVideo: bytes = video
        case .batchVideo: bytes = video + video
        case .frameThenControl: bytes = first ? video : control
        case .frameThenAudio: bytes = first ? video : audio
        case .audioOnly: bytes = audio
        default: return
        }
        peer.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            self.queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.peers.contains(where: { $0 === peer }) else { return }
                self.sendTick(peer, first: false)
            }
        })
    }
}
