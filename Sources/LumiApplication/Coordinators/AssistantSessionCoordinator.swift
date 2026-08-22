import LumiDomain

/// Errors raised by coordinator-owned operations before reaching a port.
public enum AssistantSessionCoordinatorError: Error, Equatable, Sendable {
    case identityRecognitionInProgress
    case voiceSessionStartInProgress
    case endSessionInProgress
}

/// Application dependencies for the optional member-aware voice tool session.
public struct VoiceToolCallSessionConfiguration: Sendable {
    public let port: any VoiceToolCallPort
    public let weeklySummaryUseCase: GetMemberWeeklySummaryUseCase

    public init(
        port: any VoiceToolCallPort,
        weeklySummaryUseCase: GetMemberWeeklySummaryUseCase
    ) {
        self.port = port
        self.weeklySummaryUseCase = weeklySummaryUseCase
    }
}

private struct VoiceStartPreparation: Sendable {
    let events: AsyncStream<VoiceSessionEvent>
    let toolRunner: VoiceToolCallSessionRunner?
}

/// Owns the active Phase 1 assistant session state and coordinates orientation.
public actor AssistantSessionCoordinator {
    private let hardware: any HardwareControlPort
    private let identity: any IdentityRecognitionPort
    private let voice: any VoiceSessionPort
    private let memberAddressResolver: @Sendable (MemberID) -> VoiceMemberAddress?
    private let voiceToolCallConfiguration: VoiceToolCallSessionConfiguration?
    private let reducer: AssistantStateReducer

    public private(set) var state: AssistantState
    public private(set) var recognitionResult: RecognitionResult?
    public private(set) var voiceRequiresRetry: Bool

    private var nextSubscriberID: UInt64 = 0
    private var subscribers: [UInt64: AsyncStream<AssistantState>.Continuation] = [:]
    private var nextAuthorizationSubscriberID: UInt64 = 0
    private var authorizationSubscribers: [
        UInt64: AsyncStream<Void>.Continuation
    ] = [:]
    private var identityRecognitionInProgress = false
    private var voiceSessionStartInProgress = false
    private var voiceEventConsumerTask: Task<Void, Never>?
    private var voiceToolCallRunnerTask: Task<Void, Never>?
    private var sessionGeneration: UInt64 = 0
    private var ending = false
    private var orientationOperation: Task<Void, Error>?
    private var orientationOperationGeneration: UInt64?
    private var identityOperation: Task<RecognitionResult, Error>?
    private var identityOperationGeneration: UInt64?
    private var voiceStartOperation: Task<VoiceStartPreparation, Error>?
    private var voiceStartOperationGeneration: UInt64?

    public init(
        hardware: any HardwareControlPort,
        identity: any IdentityRecognitionPort,
        voice: any VoiceSessionPort,
        memberAddressResolver:
            @escaping @Sendable (MemberID) -> VoiceMemberAddress? = { _ in nil },
        voiceToolCallConfiguration: VoiceToolCallSessionConfiguration? = nil
    ) {
        self.hardware = hardware
        self.identity = identity
        self.voice = voice
        self.memberAddressResolver = memberAddressResolver
        self.voiceToolCallConfiguration = voiceToolCallConfiguration
        self.reducer = AssistantStateReducer()
        self.state = .idle
        self.recognitionResult = nil
        self.voiceRequiresRetry = false
    }

    /// Returns an independent read-only stream that starts with the current state.
    public func stateUpdates() -> AsyncStream<AssistantState> {
        let subscriberID = nextSubscriberID
        nextSubscriberID &+= 1

        let pair = AsyncStream<AssistantState>.makeStream(
            of: AssistantState.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let continuation = pair.continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeSubscriber(id: subscriberID)
            }
        }
        subscribers[subscriberID] = continuation
        continuation.yield(state)
        return pair.stream
    }

    /// Returns an independent stream for provider-neutral device setup
    /// routing. It emits once for each authorization invalidation observed by
    /// the coordinator's sole voice-event consumer.
    public func authorizationRequiredUpdates() -> AsyncStream<Void> {
        let subscriberID = nextAuthorizationSubscriberID
        nextAuthorizationSubscriberID &+= 1

        let pair = AsyncStream<Void>.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeAuthorizationSubscriber(id: subscriberID)
            }
        }
        authorizationSubscribers[subscriberID] = pair.continuation
        return pair.stream
    }

    /// Confirms a visitor from the idle state and returns the resulting state.
    @discardableResult
    public func confirmPresence(
        direction: PresenceDirection
    ) throws(AssistantStateTransitionError) -> AssistantState {
        try transition(.personConfirmed(direction: direction))
    }

    /// Starts orientation from the detected state and waits for confirmed arrival.
    @discardableResult
    public func beginOrientation() async throws -> AssistantState {
        guard !ending else {
            throw AssistantSessionCoordinatorError.endSessionInProgress
        }

        let originalDirection: PresenceDirection
        guard case let .detected(direction) = state else {
            return try transition(.beginOrientation)
        }
        originalDirection = direction

        let target = try targetAngle(for: originalDirection)
        let generation = sessionGeneration
        _ = try transition(.beginOrientation)

        let hardware = hardware
        let operation = Task<Void, Error> {
            try await hardware.rotate(to: target)
        }
        orientationOperation = operation
        orientationOperationGeneration = generation
        defer { clearOrientationOperation(generation: generation) }

        do {
            try await withTaskCancellationHandler(operation: {
                try await operation.value
            }, onCancel: {
                operation.cancel()
            })

            guard generation == sessionGeneration, !ending else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            return try transition(.rotationCompleted)
        } catch let originalError {
            if generation != sessionGeneration || ending {
                throw CancellationError()
            }

            await hardware.stop()

            guard generation == sessionGeneration, !ending else {
                throw CancellationError()
            }

            do {
                _ = try transition(.orientationFailed(direction: originalDirection))
            } catch {
                // No public coordinator operation can change rotating before this
                // recovery runs; a reducer failure therefore indicates a broken
                // single-owner invariant rather than a recoverable hardware error.
                preconditionFailure(
                    "Orientation failure recovery requires the coordinator to remain rotating"
                )
            }
            throw originalError
        }
    }

    /// Resolves the current visitor after orientation has reached recognizing.
    ///
    /// The coordinator owns the operation so concurrent calls cannot issue a
    /// second port request. Adapter failures are intentionally treated as an
    /// unknown visitor; cancellation propagates to the caller.
    public func recognizeVisitor() async throws -> RecognitionResult {
        guard !ending else {
            throw AssistantSessionCoordinatorError.endSessionInProgress
        }

        guard case .recognizing = state else {
            // Ask the Domain reducer to reject the event so callers retain the
            // typed transition error and the state remains unchanged.
            _ = try transition(.identityResolved(.unknown))
            preconditionFailure(
                "Identity resolution unexpectedly became legal outside recognizing"
            )
        }

        guard !identityRecognitionInProgress else {
            throw AssistantSessionCoordinatorError.identityRecognitionInProgress
        }

        identityRecognitionInProgress = true

        let generation = sessionGeneration
        let identity = identity
        let operation = Task<RecognitionResult, Error> {
            try await identity.recognizeCurrentVisitor()
        }
        identityOperation = operation
        identityOperationGeneration = generation
        defer { clearIdentityOperation(generation: generation) }

        do {
            try Task.checkCancellation()
            let result = try await withTaskCancellationHandler(operation: {
                try await operation.value
            }, onCancel: {
                operation.cancel()
            })

            guard generation == sessionGeneration, !ending else {
                throw CancellationError()
            }
            try Task.checkCancellation()

            _ = try transition(.identityResolved(result))
            recognitionResult = result
            return result
        } catch {
            if generation != sessionGeneration || ending {
                throw CancellationError()
            }

            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }

            let fallback: RecognitionResult = .unknown
            _ = try transition(.identityResolved(fallback))
            recognitionResult = fallback
            return fallback
        }
    }

    /// Starts a privacy-safe voice session from the greeting state.
    ///
    /// The voice adapter is asked for its event stream before startup so no
    /// readiness or lifecycle event can be lost. The coordinator remains the
    /// sole consumer and owns every resulting state transition.
    @discardableResult
    public func startVoiceSession(
        direction: VoiceConversationDirection = .general
    ) async throws -> AssistantState {
        guard !ending else {
            throw AssistantSessionCoordinatorError.endSessionInProgress
        }

        guard case .greeting = state else {
            return try transition(.voiceSessionReady)
        }

        guard !voiceSessionStartInProgress else {
            throw AssistantSessionCoordinatorError.voiceSessionStartInProgress
        }

        guard let recognitionResult else {
            preconditionFailure(
                "AssistantSessionCoordinator invariant violated: greeting requires recognitionResult"
            )
        }

        voiceSessionStartInProgress = true

        let generation = sessionGeneration

        let context: VoiceContext
        let memberID: MemberID?
        let memberAddress: VoiceMemberAddress?
        switch recognitionResult {
        case let .known(knownMemberID, _):
            context = .returningMember
            memberID = knownMemberID
            memberAddress = memberAddressResolver(knownMemberID)
        case .unknown:
            context = .visitor
            memberID = nil
            memberAddress = nil
        }

        let voice = voice
        let toolConfiguration = voiceToolCallConfiguration
        let operation = Task<VoiceStartPreparation, Error> {
            try Task.checkCancellation()
            let events = await voice.eventUpdates()
            try Task.checkCancellation()
            let toolRunner: VoiceToolCallSessionRunner?
            if let toolConfiguration, let memberID {
                toolRunner = await VoiceToolCallSessionRunner.prepare(
                    port: toolConfiguration.port,
                    memberID: memberID,
                    weeklySummaryUseCase: toolConfiguration.weeklySummaryUseCase
                )
            } else {
                toolRunner = nil
            }
            try Task.checkCancellation()
            try await voice.start(
                context: context,
                direction: direction,
                memberAddress: memberAddress
            )
            return VoiceStartPreparation(events: events, toolRunner: toolRunner)
        }
        voiceStartOperation = operation
        voiceStartOperationGeneration = generation
        defer { clearVoiceStartOperation(generation: generation) }

        do {
            try Task.checkCancellation()
            let preparation = try await withTaskCancellationHandler(operation: {
                try await operation.value
            }, onCancel: {
                operation.cancel()
            })

            guard generation == sessionGeneration, !ending else {
                throw CancellationError()
            }

            _ = try transition(.voiceSessionReady)
            voiceRequiresRetry = false
            startVoiceEventConsumer(preparation.events, generation: generation)
            if let toolRunner = preparation.toolRunner {
                startVoiceToolCallRunner(toolRunner, generation: generation)
            }
            return state
        } catch {
            if generation != sessionGeneration || ending {
                throw CancellationError()
            }

            await voice.stop()
            if error is CancellationError || Task.isCancelled {
                voiceRequiresRetry = false
                throw CancellationError()
            }

            voiceRequiresRetry = true
            throw error
        }
    }

    /// Ends the active session and returns the device home before publishing idle.
    ///
    /// The semantic state and session context remain unchanged until the hardware
    /// confirms arrival at Home. A failed or cancelled return can therefore be
    /// retried without losing the current interaction context.
    @discardableResult
    public func endSession() async throws -> AssistantState {
        guard !ending else {
            throw AssistantSessionCoordinatorError.endSessionInProgress
        }

        // Preflight through the reducer before any side effect. Idle and offline
        // therefore reject with the Domain error and do not acquire the gate.
        _ = try reducer.reduce(state, event: .sessionEnded)

        let sourceState = state
        ending = true
        defer { ending = false }
        sessionGeneration &+= 1
        cancelPendingOperations()
        voiceEventConsumerTask?.cancel()
        voiceEventConsumerTask = nil

        let toolRunnerTask = voiceToolCallRunnerTask
        voiceToolCallRunnerTask = nil
        toolRunnerTask?.cancel()
        if let toolRunnerTask {
            await toolRunnerTask.value
        }

        // Voice is always stopped for an accepted end, even for states that did
        // not currently have a live voice session.
        await voice.stop()

        var preHomeStopIssued = false
        if Task.isCancelled {
            await hardware.stop()
            throw CancellationError()
        }

        if case .rotating = sourceState {
            preHomeStopIssued = true
            await hardware.stop()
        }

        if Task.isCancelled {
            if !preHomeStopIssued {
                await hardware.stop()
            }
            throw CancellationError()
        }

        do {
            // A successful return is the adapter's confirmation that Home was
            // reached. If cancellation arrives after this returns, the confirmed
            // arrival still wins and the session may safely publish idle.
            try await hardware.returnHome()
        } catch {
            await hardware.stop()
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }

        _ = try transition(.sessionEnded)
        recognitionResult = nil
        voiceRequiresRetry = false
        return state
    }

    private func transition(
        _ event: AssistantSessionEvent
    ) throws(AssistantStateTransitionError) -> AssistantState {
        let nextState = try reducer.reduce(state, event: event)
        guard nextState != state else { return state }

        state = nextState
        publish(nextState)
        return nextState
    }

    private func publish(_ nextState: AssistantState) {
        var terminatedSubscribers: [UInt64] = []
        for (id, continuation) in subscribers {
            if case .terminated = continuation.yield(nextState) {
                terminatedSubscribers.append(id)
            }
        }
        for id in terminatedSubscribers {
            subscribers.removeValue(forKey: id)
        }
    }

    private func removeSubscriber(id: UInt64) {
        subscribers.removeValue(forKey: id)
    }

    private func removeAuthorizationSubscriber(id: UInt64) {
        authorizationSubscribers.removeValue(forKey: id)
    }

    private func clearOrientationOperation(generation: UInt64) {
        guard orientationOperationGeneration == generation else { return }
        orientationOperation = nil
        orientationOperationGeneration = nil
    }

    private func clearIdentityOperation(generation: UInt64) {
        guard identityOperationGeneration == generation else { return }
        identityOperation = nil
        identityOperationGeneration = nil
        identityRecognitionInProgress = false
    }

    private func clearVoiceStartOperation(generation: UInt64) {
        guard voiceStartOperationGeneration == generation else { return }
        voiceStartOperation = nil
        voiceStartOperationGeneration = nil
        voiceSessionStartInProgress = false
    }

    private func cancelPendingOperations() {
        orientationOperation?.cancel()
        identityOperation?.cancel()
        voiceStartOperation?.cancel()

        orientationOperation = nil
        orientationOperationGeneration = nil
        identityOperation = nil
        identityOperationGeneration = nil
        voiceStartOperation = nil
        voiceStartOperationGeneration = nil
        identityRecognitionInProgress = false
        voiceSessionStartInProgress = false
    }

    private func startVoiceEventConsumer(
        _ events: AsyncStream<VoiceSessionEvent>,
        generation: UInt64
    ) {
        voiceEventConsumerTask?.cancel()
        voiceEventConsumerTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.consumeVoiceEvent(event, generation: generation)
            }
        }
    }

    private func startVoiceToolCallRunner(
        _ runner: VoiceToolCallSessionRunner,
        generation: UInt64
    ) {
        voiceToolCallRunnerTask = Task { [weak self] in
            do {
                try await runner.run()
            } catch {
                await self?.consumeVoiceToolCallRunnerError(
                    error,
                    generation: generation
                )
            }
        }
    }

    private func consumeVoiceToolCallRunnerError(
        _ error: any Error,
        generation: UInt64
    ) {
        guard generation == sessionGeneration, !ending else { return }
        guard !(error is CancellationError), !Task.isCancelled else { return }
        voiceRequiresRetry = true
    }

    private func consumeVoiceEvent(
        _ event: VoiceSessionEvent,
        generation: UInt64
    ) {
        guard generation == sessionGeneration, !ending else { return }

        switch event {
        case .failure:
            voiceRequiresRetry = true
        case .authorizationRequired:
            publishAuthorizationRequired()
        case .assistantInterrupted:
            applyVoiceTransition(.userSpeechStarted)
        case .userSpeechStarted:
            applyVoiceTransition(.userSpeechStarted)
        case .userSpeechEnded:
            applyVoiceTransition(.userSpeechEnded)
        case .responseReady:
            applyVoiceTransition(.responseReady)
        }
    }

    private func applyVoiceTransition(_ event: AssistantSessionEvent) {
        do {
            _ = try transition(event)
            voiceRequiresRetry = false
        } catch {
            // Illegal or stale provider events are a retryable voice condition;
            // they must never mutate the semantic state or expose adapter data.
            voiceRequiresRetry = true
        }
    }

    private func publishAuthorizationRequired() {
        var terminatedSubscribers: [UInt64] = []
        for (id, continuation) in authorizationSubscribers {
            if case .terminated = continuation.yield(()) {
                terminatedSubscribers.append(id)
            }
        }
        for id in terminatedSubscribers {
            authorizationSubscribers.removeValue(forKey: id)
        }
    }

    private func targetAngle(
        for direction: PresenceDirection
    ) throws(RotationAngleError) -> RotationAngle {
        switch direction {
        case .left:
            try RotationAngle(degrees: -90)
        case .center:
            try RotationAngle(degrees: 0)
        case .right:
            try RotationAngle(degrees: 90)
        }
    }

    deinit {
        voiceEventConsumerTask?.cancel()
        voiceToolCallRunnerTask?.cancel()
        for continuation in subscribers.values {
            continuation.finish()
        }
        for continuation in authorizationSubscribers.values {
            continuation.finish()
        }
    }
}
