import Foundation
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
    public let weeklySummaryUseCase: GetMemberWeeklySummaryUseCase?

    public init(
        port: any VoiceToolCallPort,
        weeklySummaryUseCase: GetMemberWeeklySummaryUseCase? = nil
    ) {
        self.port = port
        self.weeklySummaryUseCase = weeklySummaryUseCase
    }
}

/// Dependencies for the consented, local member-memory portion of one voice
/// session. The time and session-ID providers keep lifecycle tests
/// deterministic without moving clock logic into Domain.
public struct MemberInteractionMemorySessionConfiguration: Sendable {
    public let store: any MemberInteractionMemoryStore
    public let now: @Sendable () -> Date
    public let sessionID: @Sendable () -> String

    public init(
        store: any MemberInteractionMemoryStore,
        now: @escaping @Sendable () -> Date = { Date() },
        sessionID: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.store = store
        self.now = now
        self.sessionID = sessionID
    }
}

/// Application dependencies for the Unknown visitor's consented enrollment
/// tool session.
public struct VisitorEnrollmentToolCallSessionConfiguration: Sendable {
    public let port: any VoiceToolCallPort
    public let enrollmentPort: any VisitorEnrollmentPort

    public init(
        port: any VoiceToolCallPort,
        enrollmentPort: any VisitorEnrollmentPort
    ) {
        self.port = port
        self.enrollmentPort = enrollmentPort
    }
}

private enum PreparedVoiceToolCallRunner: Sendable {
    case returningMember(VoiceToolCallSessionRunner)
    case visitorEnrollment(VisitorEnrollmentToolCallSessionRunner)

    func run() async throws {
        switch self {
        case let .returningMember(runner):
            try await runner.run()
        case let .visitorEnrollment(runner):
            try await runner.run()
        }
    }
}

private struct VoiceStartPreparation: Sendable {
    let events: AsyncStream<VoiceSessionEvent>
    let toolRunner: PreparedVoiceToolCallRunner?
    let memorySession: MemberInteractionMemorySession?
    let memoryContext: VoiceMemberMemoryContext?
}

/// Owns the active Phase 1 assistant session state and coordinates orientation.
public actor AssistantSessionCoordinator {
    private let hardware: any HardwareControlPort
    private let identity: any IdentityRecognitionPort
    private let voice: any VoiceSessionPort
    private let memberAddressResolver:
        @Sendable (MemberID) async -> VoiceMemberAddress?
    private let voiceToolCallConfiguration: VoiceToolCallSessionConfiguration?
    private let visitorEnrollmentToolCallConfiguration:
        VisitorEnrollmentToolCallSessionConfiguration?
    private let memberMemoryConfiguration:
        MemberInteractionMemorySessionConfiguration?
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
    private var nextConversationEndSubscriberID: UInt64 = 0
    private var conversationEndSubscribers: [
        UInt64: AsyncStream<Void>.Continuation
    ] = [:]
    private var nextVoiceTurnCompletionSubscriberID: UInt64 = 0
    private var voiceTurnCompletionSubscribers: [
        UInt64: AsyncStream<Bool>.Continuation
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
    private var voiceSessionIsActive = false
    private var voiceWasStoppedForConversationEnd = false
    private var conversationEndStopTask: Task<Void, Never>?
    private var assistantOutputHasStarted = false
    private var assistantOutputIsActive = false
    private var memberMemorySession: MemberInteractionMemorySession?
    private var memberMemoryContext: VoiceMemberMemoryContext?
    private var memberMemoryMeetingRecorded = false
    private var memberMemoryMeetingWriteInFlight = false
    private var memberMemoryMutationInProgress = false

    public init(
        hardware: any HardwareControlPort,
        identity: any IdentityRecognitionPort,
        voice: any VoiceSessionPort,
        memberAddressResolver:
            @escaping @Sendable (MemberID) async -> VoiceMemberAddress? = { _ in nil },
        voiceToolCallConfiguration: VoiceToolCallSessionConfiguration? = nil,
        visitorEnrollmentToolCallConfiguration:
            VisitorEnrollmentToolCallSessionConfiguration? = nil,
        memberMemoryConfiguration: MemberInteractionMemorySessionConfiguration? = nil
    ) {
        self.hardware = hardware
        self.identity = identity
        self.voice = voice
        self.memberAddressResolver = memberAddressResolver
        self.voiceToolCallConfiguration = voiceToolCallConfiguration
        self.visitorEnrollmentToolCallConfiguration =
            visitorEnrollmentToolCallConfiguration
        self.memberMemoryConfiguration = memberMemoryConfiguration
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

    /// Returns an independent stream for a confirmed natural conversation
    /// closing. The stream carries no transcript or provider payload; App
    /// composition uses it to complete the existing return-home flow.
    public func conversationEndRequests() -> AsyncStream<Void> {
        let subscriberID = nextConversationEndSubscriberID
        nextConversationEndSubscriberID &+= 1

        let pair = AsyncStream<Void>.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeConversationEndSubscriber(id: subscriberID)
            }
        }
        conversationEndSubscribers[subscriberID] = pair.continuation
        return pair.stream
    }

    /// Ends a session only after the current conversational turn reaches a
    /// provider-confirmed audio boundary.
    ///
    /// While a live voice session is greeting, listening, thinking, or
    /// producing audio, internal callers such as departure monitoring must use
    /// this operation so a camera result cannot truncate assistant speech.
    @discardableResult
    public func endSessionAfterCurrentVoiceTurnCompletes() async throws -> AssistantState {
        let updates = voiceTurnCompletionUpdates()
        for await canEndWithoutTruncatingVoice in updates {
            try Task.checkCancellation()
            if canEndWithoutTruncatingVoice {
                return try await endSession()
            }
        }
        throw CancellationError()
    }

    /// Confirms a visitor from the idle state and returns the resulting state.
    @discardableResult
    public func confirmPresence(
        direction: PresenceDirection
    ) throws -> AssistantState {
        guard !memberMemoryMutationInProgress else {
            throw AssistantSessionCoordinatorError.endSessionInProgress
        }
        return try transition(.personConfirmed(direction: direction))
    }

    /// Starts orientation from the detected state and waits for confirmed arrival.
    @discardableResult
    public func beginOrientation() async throws -> AssistantState {
        guard !ending, !memberMemoryMutationInProgress else {
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
        guard !ending, !memberMemoryMutationInProgress else {
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

    /// Pre-warms the voice adapter resources before voice startup.
    public func prewarmVoiceSession() async {
        guard !ending, !memberMemoryMutationInProgress else { return }
        await voice.prewarm()
    }

    /// Invalidates the active provider context before a management clear or
    /// disable. The management operation then removes the persisted events;
    /// this ordering prevents an already-loaded opener from being reused.
    public func invalidateMemberMemoryContext() async {
        await memberMemorySession?.invalidate()
        memberMemoryContext = nil
        await voice.invalidateMemberMemoryContext()
    }

    /// Quiesces the coordinator before the operator changes member-memory
    /// consent or clears data. Startup/reconnect work is cancelled first, the
    /// session-bound context is invalidated, and an active session completes
    /// the ordinary return-home flow. A failed home movement throws before a
    /// caller can report the storage mutation as successful.
    public func prepareForMemberMemoryMutation() async throws {
        guard !ending, !memberMemoryMutationInProgress else {
            throw AssistantSessionCoordinatorError.endSessionInProgress
        }

        memberMemoryMutationInProgress = true
        defer { memberMemoryMutationInProgress = false }

        await memberMemorySession?.invalidate()
        memberMemoryContext = nil

        guard state != .idle, state != .offline else {
            sessionGeneration &+= 1
            cancelPendingOperations()
            await voice.stop()
            await voice.invalidateMemberMemoryContext()
            voiceSessionIsActive = false
            voiceWasStoppedForConversationEnd = false
            memberMemorySession = nil
            memberMemoryMeetingRecorded = false
            memberMemoryMeetingWriteInFlight = false
            return
        }

        do {
            _ = try await endSessionImpl()
        } catch {
            // `endSession` already stopped provider output before attempting
            // Home. Make the provider-side memory boundary fail closed even
            // when the hardware cannot complete the return-home movement.
            await voice.invalidateMemberMemoryContext()
            throw error
        }
        await voice.invalidateMemberMemoryContext()
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
        guard !ending, !memberMemoryMutationInProgress else {
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
        switch recognitionResult {
        case let .known(knownMemberID, _):
            context = .returningMember
            memberID = knownMemberID
        case .unknown:
            context = .visitor
            memberID = nil
        }

        let voice = voice
        let memberAddressResolver = memberAddressResolver
        let toolConfiguration = voiceToolCallConfiguration
        let visitorToolConfiguration = visitorEnrollmentToolCallConfiguration
        let memoryConfiguration = memberMemoryConfiguration
        let memoryNow: @Sendable () -> Date
        if let memoryConfiguration {
            memoryNow = memoryConfiguration.now
        } else {
            memoryNow = { Date() }
        }
        let operation = Task<VoiceStartPreparation, Error> {
            try Task.checkCancellation()
            let memberAddress: VoiceMemberAddress?
            if let memberID {
                memberAddress = await memberAddressResolver(memberID)
                try Task.checkCancellation()
            } else {
                memberAddress = nil
            }

            var memorySession: MemberInteractionMemorySession?
            var memoryContext: VoiceMemberMemoryContext?
            if let memberID, let memoryConfiguration {
                do {
                    let now = memoryConfiguration.now()
                    let loadResult = try await LoadMemberMemoryUseCase(
                        store: memoryConfiguration.store
                    ).execute(
                        for: memberID,
                        at: now
                    )
                    if case let .available(loaded) = loadResult {
                        let initialExerciseDisclosureRecordedAt =
                            loaded.snapshot.currentExerciseDisclosureRecordedAt
                        let session = MemberInteractionMemorySession(
                            memberID: memberID,
                            sessionID: memoryConfiguration.sessionID(),
                            initialRevision: loaded.revision,
                            initialExerciseDisclosure:
                                loaded.snapshot.currentExerciseDisclosure,
                            initialExerciseDisclosureRecordedAt:
                                initialExerciseDisclosureRecordedAt,
                            store: memoryConfiguration.store
                        )
                        memorySession = session
                        let exerciseState = await session.currentExerciseMemoryState(at: now)
                        memoryContext = VoiceMemberMemoryContext(
                            snapshot: loaded.snapshot,
                            currentExerciseState: exerciseState,
                            encounterAt: now
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Memory read failures degrade to the ordinary greeting;
                    // the voice session itself remains available.
                }
            }

            let events = await voice.eventUpdates()
            try Task.checkCancellation()
            let toolRunner: PreparedVoiceToolCallRunner?
            if let toolConfiguration, let memberID {
                toolRunner = .returningMember(
                    await VoiceToolCallSessionRunner.prepare(
                        port: toolConfiguration.port,
                        memberID: memberID,
                        weeklySummaryUseCase: toolConfiguration.weeklySummaryUseCase,
                        memorySession: memorySession,
                        now: memoryNow,
                        memoryContextDidChange: { [weak self] disclosure, recordedAt in
                            await self?.applyMemberMemoryDisclosure(
                                disclosure,
                                recordedAt: recordedAt,
                                generation: generation
                            )
                        }
                    )
                )
            } else if context == .visitor, let visitorToolConfiguration {
                toolRunner = .visitorEnrollment(
                    await VisitorEnrollmentToolCallSessionRunner.prepare(
                        port: visitorToolConfiguration.port,
                        enrollmentPort: visitorToolConfiguration.enrollmentPort
                    )
                )
            } else {
                toolRunner = nil
            }
            try Task.checkCancellation()
            try await voice.start(
                context: context,
                direction: direction,
                memberAddress: memberAddress,
                memoryContext: memoryContext
            )
            return VoiceStartPreparation(
                events: events,
                toolRunner: toolRunner,
                memorySession: memorySession,
                memoryContext: memoryContext
            )
        }
        voiceStartOperation = operation
        voiceStartOperationGeneration = generation
        defer { clearVoiceStartOperation(generation: generation) }

        do {
            let preparation = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await operation.value
            }, onCancel: {
                operation.cancel()
            })

            guard generation == sessionGeneration, !ending else {
                throw CancellationError()
            }

            voiceSessionIsActive = true
            memberMemorySession = preparation.memorySession
            memberMemoryContext = preparation.memoryContext
            memberMemoryMeetingRecorded = false
            memberMemoryMeetingWriteInFlight = false
            voiceWasStoppedForConversationEnd = false
            assistantOutputHasStarted = false
            assistantOutputIsActive = false
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
        guard !memberMemoryMutationInProgress else {
            throw AssistantSessionCoordinatorError.endSessionInProgress
        }
        return try await endSessionImpl()
    }

    @discardableResult
    private func endSessionImpl() async throws -> AssistantState {
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
        await memberMemorySession?.invalidate()
        cancelPendingOperations()
        voiceEventConsumerTask?.cancel()
        voiceEventConsumerTask = nil

        let toolRunnerTask = voiceToolCallRunnerTask
        voiceToolCallRunnerTask = nil
        toolRunnerTask?.cancel()
        if let toolRunnerTask {
            await toolRunnerTask.value
        }

        // A natural closing already stops voice before its Application signal
        // is published. Keep the accepted end idempotent while preserving the
        // existing stop behavior for every other end cause and state.
        let voiceAlreadyStopped = voiceWasStoppedForConversationEnd
        voiceWasStoppedForConversationEnd = false
        if let stopTask = conversationEndStopTask {
            await stopTask.value
            conversationEndStopTask = nil
        } else if !voiceAlreadyStopped {
            await voice.stop()
        }

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

        voiceSessionIsActive = false
        voiceWasStoppedForConversationEnd = false
        assistantOutputHasStarted = false
        assistantOutputIsActive = false
        _ = try transition(.sessionEnded)
        recognitionResult = nil
        memberMemorySession = nil
        memberMemoryContext = nil
        memberMemoryMeetingRecorded = false
        memberMemoryMeetingWriteInFlight = false
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
        publishVoiceTurnCompletionReadiness()
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

    private func removeConversationEndSubscriber(id: UInt64) {
        conversationEndSubscribers.removeValue(forKey: id)
    }

    private func voiceTurnCompletionUpdates() -> AsyncStream<Bool> {
        let subscriberID = nextVoiceTurnCompletionSubscriberID
        nextVoiceTurnCompletionSubscriberID &+= 1

        let pair = AsyncStream<Bool>.makeStream(
            of: Bool.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeVoiceTurnCompletionSubscriber(id: subscriberID)
            }
        }
        voiceTurnCompletionSubscribers[subscriberID] = pair.continuation
        pair.continuation.yield(canEndWithoutTruncatingVoice)
        return pair.stream
    }

    private var canEndWithoutTruncatingVoice: Bool {
        guard voiceSessionIsActive || voiceSessionStartInProgress else {
            return true
        }
        guard state == .speaking else { return false }
        return assistantOutputHasStarted && !assistantOutputIsActive
    }

    private func publishVoiceTurnCompletionReadiness() {
        let value = canEndWithoutTruncatingVoice
        var terminatedSubscribers: [UInt64] = []
        for (id, continuation) in voiceTurnCompletionSubscribers {
            if case .terminated = continuation.yield(value) {
                terminatedSubscribers.append(id)
            }
        }
        for id in terminatedSubscribers {
            voiceTurnCompletionSubscribers.removeValue(forKey: id)
        }
    }

    private func removeVoiceTurnCompletionSubscriber(id: UInt64) {
        voiceTurnCompletionSubscribers.removeValue(forKey: id)
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
        _ runner: PreparedVoiceToolCallRunner,
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

    private func applyMemberMemoryDisclosure(
        _ _: MemberExerciseDisclosure?,
        recordedAt: Date,
        generation: UInt64
    ) async {
        guard generation == sessionGeneration,
              !ending,
              let context = memberMemoryContext,
              let memorySession = memberMemorySession
        else { return }

        let exerciseState = await memorySession.currentExerciseMemoryState(at: recordedAt)
        let updated = context.updatingExerciseDisclosure(
            exerciseState.disclosure, recordedAt: exerciseState.recordedAt
        )
        memberMemoryContext = updated
        await voice.updateMemberMemoryContext(updated)
    }

    private func consumeVoiceEvent(
        _ event: VoiceSessionEvent,
        generation: UInt64
    ) async {
        guard generation == sessionGeneration, !ending else { return }
        guard !voiceWasStoppedForConversationEnd else { return }

        switch event {
        case .assistantOutputStarted:
            assistantOutputHasStarted = true
            assistantOutputIsActive = true
            publishVoiceTurnCompletionReadiness()
        case .assistantOutputEnded:
            assistantOutputIsActive = false
            publishVoiceTurnCompletionReadiness()
        case .assistantOutputCleared:
            assistantOutputIsActive = false
            publishVoiceTurnCompletionReadiness()
        case .greetingCompleted:
            await recordMemberMeetingIfNeeded(generation: generation)
        case .conversationEndRequested:
            // Stop the provider before notifying App composition. This keeps
            // a provider close/retry from racing the return-home operation,
            // and also makes the event safe when no App subscriber exists.
            voiceWasStoppedForConversationEnd = true
            let voice = voice
            let stopTask = Task { await voice.stop() }
            conversationEndStopTask = stopTask
            await stopTask.value
            guard generation == sessionGeneration, !ending else { return }
            conversationEndStopTask = nil
            voiceSessionIsActive = false
            voiceRequiresRetry = false
            assistantOutputHasStarted = false
            assistantOutputIsActive = false
            publishVoiceTurnCompletionReadiness()
            publishConversationEndRequest()
        case .failure:
            voiceRequiresRetry = true
        case .authorizationRequired:
            publishAuthorizationRequired()
        case .assistantInterrupted:
            assistantOutputHasStarted = false
            assistantOutputIsActive = false
            applyVoiceTransition(.userSpeechStarted)
        case .userSpeechStarted:
            assistantOutputHasStarted = false
            assistantOutputIsActive = false
            applyVoiceTransition(.userSpeechStarted)
        case .userSpeechEnded:
            applyVoiceTransition(.userSpeechEnded)
        case .responseReady:
            assistantOutputHasStarted = false
            assistantOutputIsActive = false
            applyVoiceTransition(.responseReady)
        }
    }

    private func recordMemberMeetingIfNeeded(generation: UInt64) async {
        guard generation == sessionGeneration,
              !ending,
              let memorySession = memberMemorySession,
              memberMemoryContext != nil,
              !memberMemoryMeetingRecorded,
              !memberMemoryMeetingWriteInFlight
        else { return }

        memberMemoryMeetingWriteInFlight = true
        defer { memberMemoryMeetingWriteInFlight = false }
        let now = memberMemoryConfiguration?.now() ?? Date()
        do {
            let result = try await memorySession.recordMeeting(at: now)
            guard generation == sessionGeneration, !ending else { return }
            if result.wasAccepted {
                memberMemoryMeetingRecorded = true
            } else {
                memberMemoryContext = nil
                await voice.invalidateMemberMemoryContext()
            }
        } catch is CancellationError {
            return
        } catch {
            // A failed memory write leaves the current conversation usable;
            // it simply cannot claim that this meeting was remembered.
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

    private func publishConversationEndRequest() {
        var terminatedSubscribers: [UInt64] = []
        for (id, continuation) in conversationEndSubscribers {
            if case .terminated = continuation.yield(()) {
                terminatedSubscribers.append(id)
            }
        }
        for id in terminatedSubscribers {
            conversationEndSubscribers.removeValue(forKey: id)
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
        for continuation in conversationEndSubscribers.values {
            continuation.finish()
        }
        for continuation in voiceTurnCompletionSubscribers.values {
            continuation.finish()
        }
    }
}
