import Combine
import LumiApplication
import LumiDomain
import LumiInfrastructure
import LumiPresentation

/// App-side adapter for the deterministic Phase 1.3 session simulation.
///
/// The coordinator remains the only owner of the active session state. This
/// model observes its read-only stream, maps Domain state at the App boundary,
/// and exposes only the staged actions that the Simulator needs.
@MainActor
final class SessionSimulationModel: ObservableObject {
    enum VisitorIdentityChoice: String, CaseIterable, Identifiable {
        case unknown
        case known

        var id: Self { self }

        var label: String {
            switch self {
            case .unknown:
                "未知"
            case .known:
                "已知"
            }
        }
    }

    /// App-only copy context for the two end-session Simulator actions. This
    /// never crosses the coordinator or Application boundary.
    enum EndSessionCause: Equatable {
        case timeout
        case visitorLeft

        var label: String {
            switch self {
            case .timeout:
                "逾時"
            case .visitorLeft:
                "訪客離開"
            }
        }
    }

    enum PendingAction: Equatable {
        case confirmingPresence
        case beginningRotation
        case completingRotation
        case resolvingVisitor
        case startingVoice
        case userSpeechStarted
        case userSpeechEnded
        case responseReady
        case voiceFailure
        case ending(EndSessionCause)
        case returningHome(EndSessionCause)

        var label: String {
            switch self {
            case .confirmingPresence:
                "正在確認來訪者"
            case .beginningRotation:
                "等待轉向完成"
            case .completingRotation:
                "正在完成轉向"
            case .resolvingVisitor:
                "等待確認訪客身分"
            case .startingVoice:
                "正在啟動語音"
            case .userSpeechStarted:
                "正在模擬開始說話"
            case .userSpeechEnded:
                "正在模擬說話結束"
            case .responseReady:
                "正在模擬回覆就緒"
            case .voiceFailure:
                "正在模擬語音錯誤"
            case let .ending(cause):
                "正在結束工作階段（\(cause.label)）"
            case let .returningHome(cause):
                "等待回到原位（\(cause.label)）"
            }
        }
    }

    private enum SimulatedReturnHomeError: Error, Sendable {
        case injected
    }

    @Published private(set) var assistantState: AssistantState
    @Published private(set) var avatarState: AvatarVisualState
    @Published private(set) var pendingAction: PendingAction?
    @Published private(set) var errorMessage: String?
    @Published private(set) var visitorGreeting: String?
    @Published private(set) var pendingAvatarEvent: AvatarEventCommand?

    private let coordinator: AssistantSessionCoordinator
    private let hardware: MockHardwareControlPort
    private let identity: MockIdentityRecognitionAdapter
    private let voice: MockVoiceSessionPort
    private let mapper: AvatarStateMapper
    private let eventMapper: AvatarEventCommandMapper

    private static let debugKnownResult: RecognitionResult = {
        do {
            let memberID = try MemberID(rawValue: "simulator-known-visitor")
            let confidence = try RecognitionConfidence(value: 1.0)
            return .known(memberID: memberID, confidence: confidence)
        } catch {
            preconditionFailure("Simulator known identity constants must remain valid")
        }
    }()

    private static let maxPendingRequestYields = 128

    private var stateUpdatesTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var actionGeneration: UInt64 = 0

    init(
        coordinator: AssistantSessionCoordinator,
        hardware: MockHardwareControlPort,
        identity: MockIdentityRecognitionAdapter,
        voice: MockVoiceSessionPort,
        mapper: AvatarStateMapper = AvatarStateMapper(),
        eventMapper: AvatarEventCommandMapper = AvatarEventCommandMapper()
    ) {
        self.coordinator = coordinator
        self.hardware = hardware
        self.identity = identity
        self.voice = voice
        self.mapper = mapper
        self.eventMapper = eventMapper
        self.assistantState = .idle
        self.avatarState = mapper.map(.idle)
        subscribeToStateUpdates()
    }

    deinit {
        stateUpdatesTask?.cancel()
        actionTask?.cancel()
    }

    var canChooseDirection: Bool {
        assistantState == .idle && pendingAction == nil
    }

    /// End-session is available for every active semantic state, including
    /// while a normal Simulator action is waiting for its mock completion.
    var canEndSession: Bool {
        switch assistantState {
        case .idle, .offline:
            false
        default:
            !isEndSessionPending
        }
    }

    var canCompleteReturnHome: Bool {
        if case .returningHome = pendingAction { return true }
        return false
    }

    var canFailReturnHome: Bool {
        canCompleteReturnHome
    }

    private var isEndSessionPending: Bool {
        switch pendingAction {
        case .ending, .returningHome:
            true
        default:
            false
        }
    }

    var canConfirmPresence: Bool {
        canChooseDirection
    }

    var canBeginRotation: Bool {
        if case .detected = assistantState {
            return pendingAction == nil
        }
        return false
    }

    var canCompleteRotation: Bool {
        assistantState == .rotating && pendingAction == .beginningRotation
    }

    var canResolveVisitor: Bool {
        assistantState == .recognizing && pendingAction == nil
    }

    /// Voice startup is legal only after identity resolution reaches greeting.
    var canStartVoiceSession: Bool {
        assistantState == .greeting && pendingAction == nil
    }

    /// The Simulator exposes each lifecycle event as an explicit action. A
    /// pending action closes the small async gap between `emit` and the
    /// coordinator's state stream so a fast repeated tap cannot duplicate it.
    var canSimulateUserSpeechStarted: Bool {
        assistantState == .speaking && pendingAction == nil
    }

    var canSimulateUserSpeechEnded: Bool {
        assistantState == .listening && pendingAction == nil
    }

    var canSimulateResponseReady: Bool {
        assistantState == .thinking && pendingAction == nil
    }

    var canSimulateVoiceFailure: Bool {
        switch assistantState {
        case .speaking, .listening, .thinking:
            pendingAction == nil
        default:
            false
        }
    }

    /// Confirms a visitor and preserves the selected direction in Domain state.
    func confirm(direction: PresenceDirection) {
        guard canConfirmPresence else { return }
        let operationID = beginAction(.confirmingPresence)
        visitorGreeting = nil
        pendingAvatarEvent = nil
        let coordinator = coordinator
        actionTask = Task { [weak self] in
            do {
                let nextState = try await coordinator.confirmPresence(direction: direction)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.receive(nextState)
                self.finishAction(operationID)
            } catch {
                guard !Task.isCancelled else { return }
                self?.failAction(
                    message: "無法確認來訪者，請再試一次。",
                    operationID: operationID
                )
            }
        }
    }

    /// Starts the coordinator's arrival-gated orientation operation.
    func begin() {
        guard canBeginRotation else { return }
        let operationID = beginAction(.beginningRotation)
        let coordinator = coordinator
        actionTask = Task { [weak self] in
            do {
                let nextState = try await coordinator.beginOrientation()
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.receive(nextState)
                self.finishAction(operationID)
            } catch {
                guard !Task.isCancelled else { return }
                self?.failAction(
                    message: "轉向失敗，請再試一次。",
                    operationID: operationID
                )
            }
        }
    }

    /// Releases the mock adapter's pending arrival without inventing a delay.
    func completeArrival() {
        guard canCompleteRotation else { return }
        pendingAction = .completingRotation
        let hardware = hardware
        Task {
            await hardware.completeRotation()
        }
    }

    /// Starts recognition and explicitly completes the deterministic mock.
    ///
    /// The bounded yield loop observes the adapter's pending continuation
    /// without introducing wall-clock delays. The selected result is kept
    /// entirely inside this Simulator model; the UI only sees generic copy and
    /// a Presentation-owned event command.
    func resolveVisitor(_ choice: VisitorIdentityChoice) {
        guard canResolveVisitor else { return }
        let operationID = beginAction(.resolvingVisitor)

        let coordinator = coordinator
        let identity = identity
        actionTask = Task { [weak self] in
            let recognitionTask = Task {
                try await coordinator.recognizeVisitor()
            }

            do {
                var requestIsPending = false
                for _ in 0 ..< Self.maxPendingRequestYields {
                    guard !Task.isCancelled else {
                        recognitionTask.cancel()
                        self?.finishAction(operationID)
                        return
                    }
                    if await identity.hasPendingRequest {
                        requestIsPending = true
                        break
                    }
                    await Task.yield()
                }

                guard requestIsPending else {
                    recognitionTask.cancel()
                    _ = try? await recognitionTask.value
                    guard !Task.isCancelled else {
                        self?.finishAction(operationID)
                        return
                    }
                    self?.failAction(
                        message: "無法確認訪客身分，請再試一次。",
                        operationID: operationID
                    )
                    return
                }

                await identity.complete(with: Self.result(for: choice))
                let result = try await recognitionTask.value
                guard !Task.isCancelled else {
                    self?.finishAction(operationID)
                    return
                }
                guard let self else { return }
                self.applyRecognitionResult(result)
                self.finishAction(operationID)
            } catch is CancellationError {
                recognitionTask.cancel()
                if Task.isCancelled {
                    self?.finishAction(operationID)
                } else {
                    self?.failAction(
                        message: "無法確認訪客身分，請再試一次。",
                        operationID: operationID
                    )
                }
            } catch {
                guard !Task.isCancelled else {
                    self?.finishAction(operationID)
                    return
                }
                self?.failAction(
                    message: "無法確認訪客身分，請再試一次。",
                    operationID: operationID
                )
            }
        }
    }

    /// Starts the mock voice session and explicitly completes its readiness
    /// boundary. No timer is used: a bounded yield loop waits for the mock's
    /// pending request, then the same user action calls `completeStart()`.
    func startVoiceSession() {
        guard canStartVoiceSession else { return }
        let operationID = beginAction(.startingVoice)

        let coordinator = coordinator
        let voice = voice
        actionTask = Task { [weak self] in
            let startTask = Task {
                try await coordinator.startVoiceSession()
            }

            do {
                let requestIsPending = try await withTaskCancellationHandler(
                    operation: {
                        var pending = false
                        for _ in 0 ..< Self.maxPendingRequestYields {
                            try Task.checkCancellation()
                            if await voice.hasPendingStart {
                                pending = true
                                break
                            }
                            await Task.yield()
                        }
                        return pending
                    },
                    onCancel: {
                        startTask.cancel()
                    }
                )

                guard requestIsPending else {
                    startTask.cancel()
                    _ = try? await startTask.value
                    guard !Task.isCancelled else {
                        self?.finishAction(operationID)
                        return
                    }
                    self?.failAction(
                        message: Self.voiceStartErrorMessage,
                        operationID: operationID
                    )
                    return
                }

                try Task.checkCancellation()
                await voice.completeStart()
                _ = try await withTaskCancellationHandler(
                    operation: {
                        try await startTask.value
                    },
                    onCancel: {
                        startTask.cancel()
                    }
                )
                guard !Task.isCancelled else {
                    self?.finishAction(operationID)
                    return
                }
                // The coordinator's state stream publishes `speaking`; the
                // model intentionally does not own or mutate Domain state.
            } catch is CancellationError {
                startTask.cancel()
                _ = try? await startTask.value
                self?.finishAction(operationID)
            } catch {
                startTask.cancel()
                _ = try? await startTask.value
                guard !Task.isCancelled else {
                    self?.finishAction(operationID)
                    return
                }
                self?.failAction(
                    message: Self.voiceStartErrorMessage,
                    operationID: operationID
                )
            }
        }
    }

    /// Starts the shared timeout/person-left end-session action. A normal
    /// Simulator action may be interrupted. The coordinator owns cancellation
    /// of its child operation so the old App wrapper is not cancelled first
    /// (which could otherwise recover orientation before `endSession` obtains
    /// the actor); generation checks keep that wrapper from writing stale UI.
    func endSession(cause: EndSessionCause) {
        guard canEndSession else { return }
        let operationID = beginEndAction(.ending(cause))
        let coordinator = coordinator
        let hardware = hardware
        actionTask = Task { [weak self] in
            let endTask = Task {
                try await coordinator.endSession()
            }

            do {
                let requestIsPending = try await withTaskCancellationHandler(
                    operation: {
                        try await Self.waitForReturnHome(
                            hardware: hardware,
                            maxYields: Self.maxPendingRequestYields
                        )
                    },
                    onCancel: {
                        endTask.cancel()
                    }
                )

                if requestIsPending {
                    guard !Task.isCancelled else {
                        endTask.cancel()
                        _ = try? await endTask.value
                        self?.finishAction(operationID)
                        return
                    }
                    self?.markReturningHome(cause: cause, operationID: operationID)
                }

                _ = try await withTaskCancellationHandler(
                    operation: {
                        try await endTask.value
                    },
                    onCancel: {
                        endTask.cancel()
                    }
                )
                guard !Task.isCancelled else {
                    self?.finishAction(operationID)
                    return
                }
                self?.finishAction(operationID)
            } catch is CancellationError {
                endTask.cancel()
                _ = try? await endTask.value
                self?.finishAction(operationID)
            } catch {
                endTask.cancel()
                _ = try? await endTask.value
                guard !Task.isCancelled else {
                    self?.finishAction(operationID)
                    return
                }
                self?.failAction(
                    message: Self.returnHomeErrorMessage,
                    operationID: operationID
                )
            }
        }
    }

    /// Confirms the MockHardware adapter's explicit Home arrival.
    func completeReturnHome() {
        guard canCompleteReturnHome else { return }
        let hardware = hardware
        Task {
            await hardware.completeReturnHome()
        }
    }

    /// Injects an App-local Home failure; coordinator state and context remain
    /// untouched so the end action can be retried.
    func failReturnHome() {
        guard canFailReturnHome else { return }
        let hardware = hardware
        Task {
            await hardware.failPendingReturnHome(
                with: SimulatedReturnHomeError.injected
            )
        }
    }

    /// Emits `UserSpeechStarted` only while Lumi is speaking.
    func simulateUserSpeechStarted() {
        guard canSimulateUserSpeechStarted else { return }
        emitVoiceEvent(.userSpeechStarted, pendingAction: .userSpeechStarted)
    }

    /// Emits `UserSpeechEnded` only while Lumi is listening.
    func simulateUserSpeechEnded() {
        guard canSimulateUserSpeechEnded else { return }
        emitVoiceEvent(.userSpeechEnded, pendingAction: .userSpeechEnded)
    }

    /// Emits `ResponseReady` only while Lumi is thinking.
    func simulateResponseReady() {
        guard canSimulateResponseReady else { return }
        emitVoiceEvent(.responseReady, pendingAction: .responseReady)
    }

    /// Injects a payload-free voice failure while preserving the semantic
    /// state. Adapter details never cross this App-side retry message.
    func simulateVoiceFailure() {
        guard canSimulateVoiceFailure else { return }
        let operationID = beginAction(.voiceFailure)
        let voice = voice
        actionTask = Task { [weak self] in
            await voice.emit(.failure)
            guard !Task.isCancelled else {
                self?.finishAction(operationID)
                return
            }
            self?.failAction(
                message: Self.voiceRetryErrorMessage,
                operationID: operationID
            )
        }
    }

    /// Delivers the next event to the Avatar and clears it immediately.
    @discardableResult
    func consumeAvatarEvent() -> AvatarEventCommand? {
        defer { pendingAvatarEvent = nil }
        return pendingAvatarEvent
    }

    private func subscribeToStateUpdates() {
        let coordinator = coordinator
        stateUpdatesTask = Task { [weak self] in
            let updates = await coordinator.stateUpdates()
            for await nextState in updates {
                guard !Task.isCancelled else { return }
                self?.receive(nextState)
            }
        }
    }

    private func receive(_ state: AssistantState) {
        assistantState = state
        avatarState = mapper.map(state)

        if state == .idle {
            visitorGreeting = nil
            errorMessage = nil
            pendingAvatarEvent = nil
        }

        switch (pendingAction, state) {
        case (.startingVoice, .speaking),
             (.userSpeechStarted, .listening),
             (.userSpeechEnded, .thinking),
             (.responseReady, .speaking):
            // State changes are observed from the coordinator stream. This
            // clears only the matching pending action; no Domain state is
            // duplicated in the model.
            pendingAction = nil
        default:
            break
        }
    }

    private func applyRecognitionResult(_ result: RecognitionResult) {
        switch result {
        case .known:
            visitorGreeting = "歡迎回來～"
            pendingAvatarEvent = eventMapper.map(.memberRecognized)
        case .unknown:
            visitorGreeting = "嗨，歡迎妳！"
            pendingAvatarEvent = nil
        }
    }

    private static func result(for choice: VisitorIdentityChoice) -> RecognitionResult {
        switch choice {
        case .known:
            debugKnownResult
        case .unknown:
            .unknown
        }
    }

    @discardableResult
    private func beginAction(_ action: PendingAction) -> UInt64 {
        actionGeneration &+= 1
        actionTask?.cancel()
        pendingAction = action
        errorMessage = nil
        return actionGeneration
    }

    /// Starts EndSession without cancelling the caller wrapper. The
    /// coordinator's generation/cancelPendingOperations sequence must observe
    /// and stop the active operation as one actor-owned transaction.
    @discardableResult
    private func beginEndAction(_ action: PendingAction) -> UInt64 {
        actionGeneration &+= 1
        pendingAction = action
        errorMessage = nil
        return actionGeneration
    }

    private func finishAction(_ operationID: UInt64) {
        guard operationID == actionGeneration else { return }
        pendingAction = nil
        actionTask = nil
    }

    private func failAction(message: String, operationID: UInt64) {
        guard operationID == actionGeneration else { return }
        pendingAction = nil
        actionTask = nil
        errorMessage = message
    }

    private func markReturningHome(cause: EndSessionCause, operationID: UInt64) {
        guard operationID == actionGeneration else { return }
        pendingAction = .returningHome(cause)
    }

    private static func waitForReturnHome(
        hardware: MockHardwareControlPort,
        maxYields: Int
    ) async throws -> Bool {
        for _ in 0 ..< maxYields {
            try Task.checkCancellation()
            if await hardware.hasPendingReturnHome {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func emitVoiceEvent(
        _ event: VoiceSessionEvent,
        pendingAction: PendingAction
    ) {
        let operationID = beginAction(pendingAction)
        let voice = voice
        actionTask = Task { [weak self] in
            await voice.emit(event)
            guard !Task.isCancelled else {
                self?.finishAction(operationID)
                return
            }
            // Successful lifecycle events clear any prior retry message. The
            // matching state stream update clears the pending action.
            self?.errorMessage = nil
        }
    }

    private static let voiceStartErrorMessage = "語音啟動失敗，請再試一次。"
    private static let voiceRetryErrorMessage = "語音發生問題，請再試一次。"
    private static let returnHomeErrorMessage = "無法回到原位，請再試一次。"
}
