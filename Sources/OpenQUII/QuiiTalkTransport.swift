import Foundation

/// A caller-controlled two-way talk transport.
///
/// Creating a transport does not connect it. Applications must call ``connect(onState:onAudio:onFailure:)``
/// only after an explicit user action; OpenQUII never answers or acknowledges calls automatically.
public protocol IntercomTalkTransport: AnyObject, Sendable {
    func connect(
        onState: @escaping @Sendable (String) -> Void,
        onAudio: @escaping @Sendable (QuiiNativeAudioFrame) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws

    func sendPCM16Callback(_ pcm: Data) async throws
    func close() async
}

/// Explicit authentication metadata for native two-way talk.
///
/// OpenQUII does not derive, log, or persist these credentials.
public struct QuiiTalkCredentials: Equatable, Sendable {
    public let video: QuiiNativeVideoCredentials
    public let compactOEMID: String
    public let clientID: String
    public let channel: UInt16

    public init(
        video: QuiiNativeVideoCredentials,
        compactOEMID: String,
        clientID: String,
        channel: UInt16 = 1
    ) throws {
        guard channel > 0,
              !compactOEMID.isEmpty,
              !clientID.isEmpty,
              [compactOEMID, clientID].allSatisfy({
                  $0.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7e }
              }) else {
            throw QuiiTalkProtocolError.invalidAuthenticationMetadata
        }
        self.video = video
        self.compactOEMID = compactOEMID
        self.clientID = clientID
        self.channel = channel
    }
}
