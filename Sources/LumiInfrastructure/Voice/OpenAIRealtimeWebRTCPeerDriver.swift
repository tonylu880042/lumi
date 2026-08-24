import Foundation
@preconcurrency import WebRTC

/// The Infrastructure-only peer/media boundary used by the Realtime
/// transport. WebRTC framework objects never cross this boundary.
protocol OpenAIRealtimePeerDriver: OpenAIRealtimeMicrophoneLevelSource, Sendable {
    func prepare() async throws
    func createLocalOffer() async throws -> String
    func setRemoteAnswer(_ answerSDP: String) async throws
    func send(_ data: Data) async throws
    func eventUpdates() async -> AsyncStream<Data>
    func close() async
}

extension OpenAIRealtimePeerDriver {
    func microphoneLevel() async -> Double? { nil }
}

/// Stable, privacy-safe failures at the WebRTC boundary.
enum OpenAIRealtimePeerDriverError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case peerConnectionUnavailable
    case microphoneTrackUnavailable
    case dataChannelUnavailable
    case offerCreationFailed
    case localDescriptionFailed
    case invalidRemoteDescription
    case dataSendFailed
    case closed

    var description: String {
        switch self {
        case .peerConnectionUnavailable:
            return "WebRTC peer connection is unavailable."
        case .microphoneTrackUnavailable:
            return "WebRTC microphone track is unavailable."
        case .dataChannelUnavailable:
            return "WebRTC data channel is unavailable."
        case .offerCreationFailed:
            return "WebRTC offer creation failed."
        case .localDescriptionFailed:
            return "WebRTC local description failed."
        case .invalidRemoteDescription:
            return "WebRTC remote description was rejected."
        case .dataSendFailed:
            return "WebRTC data send failed."
        case .closed:
            return "WebRTC peer driver is closed."
        }
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: ["reason": description], displayStyle: .enum)
    }
}

/// A concrete WebRTC peer/media driver for OpenAI Realtime.
///
/// WebRTC's Objective-C delegate callbacks may arrive on framework-owned
/// threads. The driver owns all mutable state on MainActor and re-enters that
/// isolation before publishing data or mutating the peer/data-channel state.
@MainActor
final class OpenAIRealtimeWebRTCPeerDriver:
    NSObject,
    OpenAIRealtimePeerDriver,
    RTCPeerConnectionDelegate,
    RTCDataChannelDelegate
{
    private let factory: RTCPeerConnectionFactory
    private let eventStream: AsyncStream<Data>
    private var eventContinuation: AsyncStream<Data>.Continuation

    private var peerConnection: RTCPeerConnection?
    private var localMicrophoneTrack: RTCAudioTrack?
    private var localMicrophoneSender: RTCRtpSender?
    private var dataChannel: RTCDataChannel?
    private var pendingOffer: CheckedContinuation<String, any Error>?
    private var pendingRemoteAnswer: CheckedContinuation<Void, any Error>?
    private var isPrepared = false
    private var isClosed = false

    private enum RemoteAudioPolicy {
        static let gain = 2.0
    }

    /// The factory is owned by this driver instance; no process-wide WebRTC
    /// singleton is used. The injectable initializer keeps framework creation
    /// deterministic for callers that need to control construction.
    init(factory: RTCPeerConnectionFactory = RTCPeerConnectionFactory()) {
        self.factory = factory
        let streamAndContinuation = AsyncStream<Data>.makeStream(
            of: Data.self,
            bufferingPolicy: .unbounded
        )
        self.eventStream = streamAndContinuation.stream
        self.eventContinuation = streamAndContinuation.continuation
        super.init()
    }

    /// Internal observability used by Infrastructure tests without exposing
    /// WebRTC types to the transport boundary.
    var dataChannelLabel: String? { dataChannel?.label }
    var dataChannelIsOrdered: Bool { dataChannel?.isOrdered == true }
    var localMicrophoneTrackEnabled: Bool { localMicrophoneTrack?.isEnabled == true }

    func prepare() async throws {
        guard !isClosed else { throw OpenAIRealtimePeerDriverError.closed }
        guard !isPrepared else { return }

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        guard let peer = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self
        ) else {
            throw OpenAIRealtimePeerDriverError.peerConnectionUnavailable
        }

        let audioSource = factory.audioSource(with: constraints)
        let audioTrack = factory.audioTrack(
            with: audioSource,
            trackId: "lumi-microphone"
        )
        guard let microphoneSender = peer.add(audioTrack, streamIds: ["lumi"]) else {
            peer.close()
            throw OpenAIRealtimePeerDriverError.microphoneTrackUnavailable
        }
        audioTrack.isEnabled = true

        let dataChannelConfiguration = RTCDataChannelConfiguration()
        dataChannelConfiguration.isOrdered = true
        guard let dataChannel = peer.dataChannel(
            forLabel: "oai-events",
            configuration: dataChannelConfiguration
        ) else {
            peer.close()
            throw OpenAIRealtimePeerDriverError.dataChannelUnavailable
        }

        dataChannel.delegate = self
        self.peerConnection = peer
        self.localMicrophoneTrack = audioTrack
        self.localMicrophoneSender = microphoneSender
        self.dataChannel = dataChannel
        self.isPrepared = true
    }

    func createLocalOffer() async throws -> String {
        guard !isClosed else { throw OpenAIRealtimePeerDriverError.closed }
        guard let peer = peerConnection, isPrepared else {
            throw OpenAIRealtimePeerDriverError.peerConnectionUnavailable
        }
        guard pendingOffer == nil else {
            throw OpenAIRealtimePeerDriverError.offerCreationFailed
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio:
                    kRTCMediaConstraintsValueTrue,
            ],
            optionalConstraints: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingOffer = continuation
            peer.offer(for: constraints) { description, error in
                guard let description, error == nil else {
                    Task { @MainActor [weak self] in
                        self?.finishOffer(with: .failure(
                            OpenAIRealtimePeerDriverError.offerCreationFailed
                        ))
                    }
                    return
                }

                let sdp = description.sdp
                peer.setLocalDescription(description) { error in
                    let result: Result<String, any Error> = if error == nil {
                        .success(sdp)
                    } else {
                        .failure(OpenAIRealtimePeerDriverError.localDescriptionFailed)
                    }
                    Task { @MainActor in
                        self.finishOffer(with: result)
                    }
                }
            }
        }
    }

    func setRemoteAnswer(_ answerSDP: String) async throws {
        guard !isClosed else { throw OpenAIRealtimePeerDriverError.closed }
        guard let peer = peerConnection, isPrepared else {
            throw OpenAIRealtimePeerDriverError.invalidRemoteDescription
        }
        guard pendingRemoteAnswer == nil else {
            throw OpenAIRealtimePeerDriverError.invalidRemoteDescription
        }

        let description = RTCSessionDescription(type: .answer, sdp: answerSDP)
        try await withCheckedThrowingContinuation { continuation in
            pendingRemoteAnswer = continuation
            peer.setRemoteDescription(description) { [weak self] error in
                let result: Result<Void, any Error> = if error == nil {
                    .success(())
                } else {
                    .failure(OpenAIRealtimePeerDriverError.invalidRemoteDescription)
                }
                Task { @MainActor [weak self] in
                    self?.finishRemoteAnswer(with: result)
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw OpenAIRealtimePeerDriverError.dataChannelUnavailable }
        guard let dataChannel, dataChannel.readyState == .open else {
            throw OpenAIRealtimePeerDriverError.dataChannelUnavailable
        }

        let buffer = RTCDataBuffer(data: data, isBinary: false)
        guard dataChannel.sendData(buffer) else {
            throw OpenAIRealtimePeerDriverError.dataSendFailed
        }
    }

    func eventUpdates() async -> AsyncStream<Data> {
        eventStream
    }

    func microphoneLevel() async -> Double? {
        guard !isClosed,
              let peerConnection,
              let localMicrophoneSender else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            peerConnection.statistics(
                for: localMicrophoneSender
            ) { report in
                let levels = report.statistics.values.compactMap { statistic -> Double? in
                    guard statistic.type == "media-source",
                          let value = statistic.values["audioLevel"] as? NSNumber else {
                        return nil
                    }
                    let level = value.doubleValue
                    guard level.isFinite, (0 ... 1).contains(level) else {
                        return nil
                    }
                    return level
                }
                continuation.resume(returning: levels.max())
            }
        }
    }

    func close() async {
        handleTerminalEvent()
    }

    /// Finishes the peer/data lifecycle after a framework terminal callback.
    /// This is intentionally shared with explicit `close()` so all terminal
    /// paths release the same resources and finish the same event stream.
    /// Calling it more than once is safe.
    func handleTerminalEvent() {
        guard !isClosed else { return }
        isClosed = true
        pendingOffer?.resume(throwing: OpenAIRealtimePeerDriverError.closed)
        pendingOffer = nil
        pendingRemoteAnswer?.resume(throwing: OpenAIRealtimePeerDriverError.closed)
        pendingRemoteAnswer = nil

        dataChannel?.delegate = nil
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        localMicrophoneTrack = nil
        localMicrophoneSender = nil
        isPrepared = false
        eventContinuation.finish()
    }

    /// Re-enters the driver's actor-isolated state for framework data-channel
    /// callbacks. This helper also gives Infrastructure tests a deterministic
    /// way to exercise the same observable stream without a remote peer.
    func receiveData(_ data: Data) {
        guard !isClosed else { return }
        eventContinuation.yield(data)
    }

    private func finishOffer(with result: Result<String, any Error>) {
        guard let continuation = pendingOffer else { return }
        pendingOffer = nil
        if isClosed {
            continuation.resume(throwing: OpenAIRealtimePeerDriverError.closed)
        } else {
            continuation.resume(with: result)
        }
    }

    private func finishRemoteAnswer(with result: Result<Void, any Error>) {
        guard let continuation = pendingRemoteAnswer else { return }
        pendingRemoteAnswer = nil
        if isClosed {
            continuation.resume(throwing: OpenAIRealtimePeerDriverError.closed)
        } else {
            continuation.resume(with: result)
        }
    }

    private func enableRemoteAudio(in stream: RTCMediaStream) {
        configureRemoteAudio(in: stream)
    }

    private func enableRemoteAudio(in receiver: RTCRtpReceiver) {
        configureRemoteAudioTrack(receiver.track)
    }

    /// Shared Infrastructure seam for both legacy stream and Unified Plan
    /// receiver callbacks. The pinned WebRTC surface exposes remote-track gain
    /// through `RTCAudioTrack.source.volume`; system output volume remains an
    /// OS-owned concern.
    func configureRemoteAudio(in stream: RTCMediaStream) {
        for track in stream.audioTracks {
            configureRemoteAudioTrack(track)
        }
    }

    /// `RTCRtpReceiver.track` is typed as the base media-track class, so the
    /// runtime audio track is narrowed before applying its public source gain.
    func configureRemoteAudioTrack(_ track: RTCMediaStreamTrack?) {
        guard let track, track.kind == kRTCMediaStreamTrackKindAudio else {
            return
        }

        track.isEnabled = true
        (track as? RTCAudioTrack)?.source.volume = RemoteAudioPolicy.gain
    }

    // MARK: - RTCDataChannelDelegate

    @objc(dataChannelDidChangeState:)
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .closed else { return }
        Task { @MainActor [weak self] in
            self?.handleTerminalEvent()
        }
    }

    @objc(dataChannel:didReceiveMessageWithBuffer:)
    nonisolated func dataChannel(
        _ dataChannel: RTCDataChannel,
        didReceiveMessageWith buffer: RTCDataBuffer
    ) {
        let data = buffer.data
        Task { @MainActor [weak self] in
            self?.receiveData(data)
        }
    }

    @objc(dataChannel:didChangeBufferedAmount:)
    nonisolated func dataChannel(
        _ dataChannel: RTCDataChannel,
        didChangeBufferedAmount amount: UInt64
    ) {}

    // MARK: - RTCPeerConnectionDelegate

    @objc(peerConnection:didChangeSignalingState:)
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {}

    @objc(peerConnection:didAddStream:)
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd stream: RTCMediaStream
    ) {
        Task { @MainActor [weak self] in
            self?.enableRemoteAudio(in: stream)
        }
    }

    @objc(peerConnection:didRemoveStream:)
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove stream: RTCMediaStream
    ) {}

    @objc(peerConnectionShouldNegotiate:)
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    @objc(peerConnection:didChangeIceConnectionState:)
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {}

    @objc(peerConnection:didChangeIceGatheringState:)
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {}

    @objc(peerConnection:didGenerateIceCandidate:)
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {}

    @objc(peerConnection:didRemoveIceCandidates:)
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    @objc(peerConnection:didOpenDataChannel:)
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {
        Task { @MainActor [weak self] in
            guard let self, !self.isClosed else { return }
            dataChannel.delegate = self
        }
    }

    @objc(peerConnection:didChangeConnectionState:)
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        guard newState == .failed || newState == .closed else { return }
        Task { @MainActor [weak self] in
            self?.handleTerminalEvent()
        }
    }

    @objc(peerConnection:didAddReceiver:streams:)
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd receiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        Task { @MainActor [weak self] in
            self?.enableRemoteAudio(in: receiver)
        }
    }
}
