import Foundation

/// A clock boundary kept inside Infrastructure so credential lifetime checks
/// remain deterministic without introducing a timeout or safety margin.
protocol OpenAIRealtimeClock: Sendable {
    func now() async -> Date
}

struct OpenAIRealtimeSystemClock: OpenAIRealtimeClock, Sendable {
    func now() async -> Date { Date() }
}

/// Stable failures exposed by the concrete transport.
///
/// Collaborator errors are translated at this boundary. No framework error,
/// token, SDP, or provider payload is retained in a case or its diagnostics.
public enum OpenAIWebRTCTransportError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case expiredClientSecret
    case microphonePermissionDenied
    case audioSessionFailure
    case peerFailure
    case signalingRejected(statusCode: Int)
    case signalingFailure
    case invalidRemoteDescription
    case dataChannelUnavailable
    case transportFailure
    case closed

    public var description: String {
        switch self {
        case .expiredClientSecret:
            return "OpenAI Realtime client secret is expired."
        case .microphonePermissionDenied:
            return "Microphone permission was denied."
        case .audioSessionFailure:
            return "Audio-session setup failed."
        case .peerFailure:
            return "WebRTC peer setup failed."
        case .signalingRejected(let statusCode):
            return "SDP signaling was rejected (HTTP \(statusCode))."
        case .signalingFailure:
            return "SDP signaling failed."
        case .invalidRemoteDescription:
            return "WebRTC remote description was rejected."
        case .dataChannelUnavailable:
            return "WebRTC data channel is unavailable."
        case .transportFailure:
            return "Realtime transport failed."
        case .closed:
            return "Realtime transport is closed."
        }
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["reason": description], displayStyle: .enum)
    }
}

/// Concrete startup lifecycle for one fresh OpenAI Realtime WebRTC transport.
///
/// The peer/media, audio, permission, clock, and signaling boundaries are
/// injected so macOS tests never need a microphone, network, or credential.
/// Provider data-channel events are decoded inside this actor and exposed as a
/// stable stream. Framework and raw provider payloads never leave
/// Infrastructure.
actor OpenAIWebRTCTransport: OpenAIRealtimeTransport {
    private enum Lifecycle {
        case idle
        case connecting
        case connected
        case closed
    }

    private let clock: any OpenAIRealtimeClock
    private let permission: any OpenAIRealtimeMicrophonePermissionClient
    private let audioSession: any OpenAIRealtimeAudioSessionController
    private let peerDriver: any OpenAIRealtimePeerDriver
    private let signaling: any OpenAIRealtimeSDPSignaling

    private let eventStream: AsyncStream<OpenAIRealtimeProviderEvent>
    private let eventContinuation: AsyncStream<OpenAIRealtimeProviderEvent>.Continuation

    private var generation: UInt64 = 0
    private var lifecycle = Lifecycle.idle
    private var audioIsActive = false
    private var peerWasStarted = false
    private var sessionCreatedHandled = false
    private var eventConsumerTask: Task<Void, Never>?
    private var nextOperationID: UInt64 = 0
    private var activeOperationID: UInt64?
    private var cancelActiveOperation: (@Sendable () -> Void)?

    internal init(
        clock: any OpenAIRealtimeClock,
        permission: any OpenAIRealtimeMicrophonePermissionClient,
        audioSession: any OpenAIRealtimeAudioSessionController,
        peerDriver: any OpenAIRealtimePeerDriver,
        signaling: any OpenAIRealtimeSDPSignaling
    ) {
        self.clock = clock
        self.permission = permission
        self.audioSession = audioSession
        self.peerDriver = peerDriver
        self.signaling = signaling

        let stream = AsyncStream<OpenAIRealtimeProviderEvent>.makeStream(
            of: OpenAIRealtimeProviderEvent.self,
            bufferingPolicy: .unbounded
        )
        self.eventStream = stream.stream
        self.eventContinuation = stream.continuation
    }

    /// Starts this transport with the approved permission/media/signaling
    /// ordering. The connection purpose is captured by the generation-bound
    /// provider handshake consumer after startup completes.
    func connect(
        clientSecret: OpenAIRealtimeClientSecret,
        configuration: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose,
        enablesWeeklySummaryTool: Bool = false
    ) async throws {
        try await connect(
            clientSecret: clientSecret,
            configuration: configuration,
            purpose: purpose,
            enablesWeeklySummaryTool: enablesWeeklySummaryTool,
            enablesVisitorEnrollmentTools: false
        )
    }

    func connect(
        clientSecret: OpenAIRealtimeClientSecret,
        configuration: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose,
        enablesWeeklySummaryTool: Bool,
        enablesVisitorEnrollmentTools: Bool
    ) async throws {
        guard lifecycle != .closed else { throw OpenAIWebRTCTransportError.closed }
        guard lifecycle == .idle else {
            throw OpenAIWebRTCTransportError.transportFailure
        }

        generation &+= 1
        let acceptedGeneration = generation
        lifecycle = .connecting

        do {
            try await validateCredential(
                clientSecret,
                generation: acceptedGeneration
            )

            try await awaitCancellable {
                try await self.permission.authorize()
            }
            try ensureActive(acceptedGeneration)

            // Record the attempt before awaiting so cancellation cannot leave
            // an activated backend untracked between return and the next
            // generation check. The audio controller makes deactivation
            // idempotent when activation itself fails.
            audioIsActive = true
            try await awaitCancellable {
                try await self.audioSession.activate()
            }
            try ensureActive(acceptedGeneration)

            // Mark the peer as started before preparation so a partial driver
            // setup is always closed on failure or cancellation.
            peerWasStarted = true
            try await awaitCancellable {
                try await self.peerDriver.prepare()
            }
            try ensureActive(acceptedGeneration)

            let offer = try await awaitCancellable {
                try await self.peerDriver.createLocalOffer()
            }
            try ensureActive(acceptedGeneration)

            // This is intentionally the last check before signaling. No
            // arbitrary expiry margin, timer, retry, or timeout is applied.
            try await validateCredential(
                clientSecret,
                generation: acceptedGeneration
            )

            let answer = try await awaitCancellable {
                try await self.signaling.exchange(
                    offerSDP: offer,
                    clientSecret: clientSecret
                )
            }
            try ensureActive(acceptedGeneration)

            try await awaitCancellable {
                try await self.peerDriver.setRemoteAnswer(answer)
            }
            try ensureActive(acceptedGeneration)

            sessionCreatedHandled = false
            let peerEvents = try await awaitCancellable {
                await self.peerDriver.eventUpdates()
            }
            try ensureActive(acceptedGeneration)
            startPeerEventConsumer(
                peerEvents,
                generation: acceptedGeneration,
                configuration: configuration,
                purpose: purpose,
                enablesWeeklySummaryTool: enablesWeeklySummaryTool,
                enablesVisitorEnrollmentTools: enablesVisitorEnrollmentTools
            )
            lifecycle = .connected
        } catch {
            await abortStartup(generation: acceptedGeneration)
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw map(error)
        }
    }

    /// Returns the decoded provider-event stream for this transport.
    func eventUpdates() async -> AsyncStream<OpenAIRealtimeProviderEvent> {
        eventStream
    }

    /// Closes startup resources at most once and finishes the stable stream.
    func close() async {
        guard lifecycle != .closed else { return }
        lifecycle = .closed
        generation &+= 1
        let cancel = cancelActiveOperation
        activeOperationID = nil
        cancelActiveOperation = nil
        cancel?()
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        await cleanupStartedResources()
        eventContinuation.finish()
    }

    func send(_ data: Data) async throws {
        guard lifecycle != .closed else { throw OpenAIWebRTCTransportError.closed }
        guard lifecycle == .connected, sessionCreatedHandled else {
            throw OpenAIWebRTCTransportError.dataChannelUnavailable
        }

        let acceptedGeneration = generation
        do {
            try await awaitCancellable {
                try await self.peerDriver.send(data)
            }
            try ensureActive(acceptedGeneration)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw map(error)
        }
    }

    private func startPeerEventConsumer(
        _ peerEvents: AsyncStream<Data>,
        generation acceptedGeneration: UInt64,
        configuration: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose,
        enablesWeeklySummaryTool: Bool,
        enablesVisitorEnrollmentTools: Bool
    ) {
        let task = Task { [weak self] in
            var iterator = peerEvents.makeAsyncIterator()
            while let data = await iterator.next() {
                guard let self else { return }
                await self.consume(
                    data,
                    generation: acceptedGeneration,
                    configuration: configuration,
                    purpose: purpose,
                    enablesWeeklySummaryTool: enablesWeeklySummaryTool,
                    enablesVisitorEnrollmentTools: enablesVisitorEnrollmentTools
                )
            }

            guard let self else { return }
            await self.peerEventsFinished(generation: acceptedGeneration)
        }
        eventConsumerTask = task
    }

    private func consume(
        _ data: Data,
        generation acceptedGeneration: UInt64,
        configuration: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose,
        enablesWeeklySummaryTool: Bool,
        enablesVisitorEnrollmentTools: Bool
    ) async {
        guard isGenerationActive(acceptedGeneration), !Task.isCancelled else {
            return
        }
        guard let event = OpenAIRealtimeWireDecoder.decode(data) else {
            return
        }

        guard event == .sessionCreated else {
            eventContinuation.yield(event)
            return
        }

        guard !sessionCreatedHandled else { return }

        do {
            let update = try OpenAIRealtimeWireEncoder.sessionUpdate(
                for: configuration,
                enablesWeeklySummaryTool: enablesWeeklySummaryTool,
                enablesVisitorEnrollmentTools: enablesVisitorEnrollmentTools
            )
            try await awaitCancellable {
                try await self.peerDriver.send(update)
            }
            try ensureActive(acceptedGeneration)

            if purpose == .initial {
                let greeting = try OpenAIRealtimeWireEncoder.responseCreate()
                try await awaitCancellable {
                    try await self.peerDriver.send(greeting)
                }
                try ensureActive(acceptedGeneration)
            }

            sessionCreatedHandled = true
            eventContinuation.yield(.sessionCreated)
        } catch {
            await failHandshake(generation: acceptedGeneration)
        }
    }

    private func peerEventsFinished(generation acceptedGeneration: UInt64) async {
        guard isGenerationActive(acceptedGeneration) else { return }
        lifecycle = .closed
        generation &+= 1
        eventConsumerTask = nil
        await cleanupStartedResources()
        eventContinuation.finish()
    }

    private func failHandshake(generation acceptedGeneration: UInt64) async {
        guard isGenerationActive(acceptedGeneration) else { return }
        lifecycle = .closed
        generation &+= 1
        eventConsumerTask = nil
        await cleanupStartedResources()
        eventContinuation.yield(.error)
        eventContinuation.finish()
    }

    private func isGenerationActive(_ acceptedGeneration: UInt64) -> Bool {
        lifecycle != .closed && acceptedGeneration == generation
    }

    private func validateCredential(
        _ clientSecret: OpenAIRealtimeClientSecret,
        generation acceptedGeneration: UInt64
    ) async throws {
        try ensureActive(acceptedGeneration)
        let now = try await awaitCancellable { await self.clock.now() }
        try ensureActive(acceptedGeneration)
        guard clientSecret.expiresAt > now else {
            throw OpenAIWebRTCTransportError.expiredClientSecret
        }
    }

    private func ensureActive(_ acceptedGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard lifecycle != .closed, acceptedGeneration == generation else {
            throw CancellationError()
        }
    }

    /// Runs one collaborator operation in a child task, retaining a
    /// generation-safe cancellation hook so close() can cancel a blocking
    /// permission, media, signaling, or handshake-send operation.
    private func awaitCancellable<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let child = Task { try await operation() }
        nextOperationID &+= 1
        let operationID = nextOperationID
        activeOperationID = operationID
        cancelActiveOperation = { child.cancel() }
        defer {
            if activeOperationID == operationID {
                activeOperationID = nil
                cancelActiveOperation = nil
            }
        }
        return try await withTaskCancellationHandler(operation: {
            let value = try await child.value
            try Task.checkCancellation()
            return value
        }, onCancel: {
            child.cancel()
        })
    }

    private func abortStartup(generation acceptedGeneration: UInt64) async {
        guard acceptedGeneration == generation else { return }
        lifecycle = .closed
        generation &+= 1
        let cancel = cancelActiveOperation
        activeOperationID = nil
        cancelActiveOperation = nil
        cancel?()
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        await cleanupStartedResources()
        eventContinuation.finish()
    }

    private func cleanupStartedResources() async {
        if peerWasStarted {
            peerWasStarted = false
            await peerDriver.close()
        }
        if audioIsActive {
            audioIsActive = false
            await audioSession.deactivate()
        }
    }

    private func map(_ error: any Error) -> OpenAIWebRTCTransportError {
        if let transportError = error as? OpenAIWebRTCTransportError {
            return transportError
        }
        if error is OpenAIRealtimeMicrophonePermissionError {
            return .microphonePermissionDenied
        }
        if error is OpenAIRealtimeAudioSessionError {
            return .audioSessionFailure
        }
        if let peerError = error as? OpenAIRealtimePeerDriverError {
            switch peerError {
            case .invalidRemoteDescription:
                return .invalidRemoteDescription
            case .dataChannelUnavailable:
                return .dataChannelUnavailable
            default:
                return .peerFailure
            }
        }
        if let signalingError = error as? OpenAIRealtimeSDPSignalingError {
            switch signalingError {
            case .httpStatus(let statusCode):
                return .signalingRejected(statusCode: statusCode)
            default:
                return .signalingFailure
            }
        }
        return .transportFailure
    }
}

/// Creates a fresh concrete transport and fresh media collaborators each
/// time. The injected builder is internal so macOS tests can construct a
/// deterministic factory without pretending to have iOS audio hardware.
public struct OpenAIWebRTCTransportFactory: OpenAIRealtimeTransportFactory {
    private let builder: @Sendable () async -> any OpenAIRealtimeTransport

    internal init(
        _ builder: @escaping @Sendable () async -> any OpenAIRealtimeTransport
    ) {
        self.builder = builder
    }

    #if os(iOS)
    /// Production iOS composition. Every invocation creates new collaborators
    /// and a new actor; no process-wide transport singleton is used.
    @available(iOS 17.0, *)
    public init() {
        self.builder = {
            let peer = await MainActor.run {
                OpenAIRealtimeWebRTCPeerDriver()
            }
            return OpenAIWebRTCTransport(
                clock: OpenAIRealtimeSystemClock(),
                permission: OpenAIRealtimeMicrophonePermission(),
                audioSession: OpenAIRealtimeAudioSession(),
                peerDriver: peer,
                signaling: OpenAIRealtimeSDPSignalingClient()
            )
        }
    }
    #endif

    public func makeTransport() async -> any OpenAIRealtimeTransport {
        await builder()
    }
}
