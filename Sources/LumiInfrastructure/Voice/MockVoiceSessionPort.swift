import LumiApplication

/// Failures specific to the deterministic voice-session mock.
public enum MockVoiceSessionError: Error, Equatable, Sendable {
    case startInProgress
    case alreadyActive
}

/// Deterministic voice adapter for Application tests and Simulator flows.
///
/// Startup remains suspended until `completeStart()` or `failStart(with:)` is
/// called. Events are delivered only when explicitly emitted, and no
/// wall-clock timing or provider payloads are involved.
public actor MockVoiceSessionPort: VoiceSessionPort {
    public private(set) var startContexts: [VoiceContext] = []
    public private(set) var startDirections: [VoiceConversationDirection] = []
    public private(set) var startCallCount = 0
    public private(set) var stopCallCount = 0
    public private(set) var isActive = false

    /// Whether a startup request is waiting for explicit completion.
    public var hasPendingStart: Bool {
        pendingStart != nil
    }

    private struct PendingStart {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var nextStartID: UInt64 = 0
    private var nextSubscriberID: UInt64 = 0
    private var pendingStart: PendingStart?
    private var subscribers: [UInt64: AsyncStream<VoiceSessionEvent>.Continuation] = [:]

    public init() {}

    public func start(context: VoiceContext) async throws {
        try await start(context: context, direction: .general)
    }

    public func start(
        context: VoiceContext,
        direction: VoiceConversationDirection
    ) async throws {
        let requestID = nextStartID
        nextStartID &+= 1
        startCallCount += 1
        startContexts.append(context)
        startDirections.append(direction)

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                guard !isActive else {
                    continuation.resume(throwing: MockVoiceSessionError.alreadyActive)
                    return
                }

                guard pendingStart == nil else {
                    continuation.resume(throwing: MockVoiceSessionError.startInProgress)
                    return
                }

                pendingStart = PendingStart(
                    id: requestID,
                    continuation: continuation
                )
            }
        }, onCancel: {
            Task { await self.cancelPendingStart(id: requestID) }
        })
    }

    /// Completes the active startup request and marks the voice session ready.
    /// Calling this when no matching request is pending is intentionally a
    /// no-op, including after caller cancellation or `stop()`.
    public func completeStart() {
        guard let pendingStart else { return }
        self.pendingStart = nil
        isActive = true
        pendingStart.continuation.resume()
    }

    /// Fails the active startup request with an injected application-safe
    /// error. Calling this when no request is pending is intentionally a
    /// no-op.
    public func failStart(with error: any Error) {
        guard let pendingStart else { return }
        self.pendingStart = nil
        pendingStart.continuation.resume(throwing: error)
    }

    public func eventUpdates() async -> AsyncStream<VoiceSessionEvent> {
        let subscriberID = nextSubscriberID
        nextSubscriberID &+= 1

        let pair = AsyncStream<VoiceSessionEvent>.makeStream(
            of: VoiceSessionEvent.self,
            bufferingPolicy: .unbounded
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeSubscriber(id: subscriberID)
            }
        }
        subscribers[subscriberID] = pair.continuation
        return pair.stream
    }

    /// Delivers one semantic event to every current subscriber.
    public func emit(_ event: VoiceSessionEvent) {
        guard isActive else { return }

        var terminatedSubscribers: [UInt64] = []
        for (id, continuation) in subscribers {
            if case .terminated = continuation.yield(event) {
                terminatedSubscribers.append(id)
            }
        }
        for id in terminatedSubscribers {
            subscribers.removeValue(forKey: id)
        }
    }

    /// Stops the session, safely ending pending startup and event streams.
    /// Repeated calls remain safe and are recorded in `stopCallCount`.
    public func stop() async {
        stopCallCount += 1
        isActive = false
        cancelCurrentStart()

        let activeSubscribers = Array(subscribers.values)
        subscribers.removeAll()
        for continuation in activeSubscribers {
            continuation.finish()
        }
    }

    private func cancelPendingStart(id requestID: UInt64) {
        guard let pendingStart, pendingStart.id == requestID else { return }
        self.pendingStart = nil
        pendingStart.continuation.resume(throwing: CancellationError())
    }

    private func cancelCurrentStart() {
        guard let pendingStart else { return }
        self.pendingStart = nil
        pendingStart.continuation.resume(throwing: CancellationError())
    }

    private func removeSubscriber(id subscriberID: UInt64) {
        subscribers.removeValue(forKey: subscriberID)
    }
}
