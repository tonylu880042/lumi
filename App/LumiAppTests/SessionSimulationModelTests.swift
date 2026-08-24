import Combine
import LumiDomain
import LumiApplication
import LumiInfrastructure
import Testing
@testable import LumiApp

@MainActor
@Suite("Session simulation dual-mode wrapper", .serialized)
struct SessionSimulationModelTests {
    @Test("Conversation direction choices are payload-free and use the product labels")
    func conversationDirectionChoicesArePayloadFreeAndLabelled() {
        let choices = SessionSimulationModel.ConversationDirectionChoice.allCases

        #expect(choices == [
            .general,
            .preWorkoutReminder,
            .postWorkoutReview
        ])
        #expect(choices.map(\.label) == ["一般", "運動前提醒", "運動後 review"])

        for choice in choices {
            #expect(Mirror(reflecting: choice).children.isEmpty)
        }
    }

    @Test("Selected direction reaches voice startup for an unknown visitor")
    func selectedDirectionReachesVoiceStartupForUnknownVisitor() async throws {
        let hardware = MockHardwareControlPort()
        let identity = MockIdentityRecognitionAdapter()
        let voice = MockVoiceSessionPort()
        let controlsRecorder = MockControlsRecorder(voice: voice)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voiceSimulationControls: controlsRecorder.controls()
        )

        try await moveToGreeting(model: model, hardware: hardware)
        #expect(model.canStartVoiceSession)

        model.startVoiceSession(direction: .postWorkoutReview)
        try #require(await controlsRecorder.waitForCompleteStartCall())
        #expect(await voice.startContexts == [.visitor])
        #expect(await voice.startDirections == [.postWorkoutReview])
        #expect(model.canStartVoiceSession == false)

        await controlsRecorder.allowCompleteStart()
        try #require(await waitUntilCurrent { model.assistantState == .speaking })
    }

    @Test("Failed direction startup remains retryable with the selected direction")
    func failedDirectionStartupRetainsRetryChoice() async throws {
        let hardware = MockHardwareControlPort()
        let identity = MockIdentityRecognitionAdapter()
        let voice = MockVoiceSessionPort()
        let controlsRecorder = MockControlsRecorder(voice: voice)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voiceSimulationControls: controlsRecorder.controls()
        )

        try await moveToGreeting(model: model, hardware: hardware)
        model.startVoiceSession(direction: .preWorkoutReminder)
        try #require(await controlsRecorder.waitForCompleteStartCall())
        await voice.failStart(with: TestVoiceFailure.injected)
        await controlsRecorder.allowCompleteStart()

        try #require(await waitUntilCurrent {
            model.errorMessage == "語音啟動失敗，請再試一次。"
        })
        #expect(model.canStartVoiceSession)

        await controlsRecorder.resetCompleteStartGate()
        model.startVoiceSession(direction: .preWorkoutReminder)
        try #require(await controlsRecorder.waitForCompleteStartCall())
        await controlsRecorder.allowCompleteStart()

        try #require(await waitUntilCurrent { model.assistantState == .speaking })
        #expect(await voice.startDirections == [
            .preWorkoutReminder,
            .preWorkoutReminder
        ])
    }

    @Test("Mock mode keeps explicit readiness and injected event controls")
    func mockModeKeepsReadinessAndEvents() async throws {
        let hardware = MockHardwareControlPort()
        let identity = MockIdentityRecognitionAdapter()
        let voice = MockVoiceSessionPort()
        let controlsRecorder = MockControlsRecorder(voice: voice)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voiceSimulationControls: controlsRecorder.controls()
        )

        try await moveToGreeting(model: model, hardware: hardware)
        #expect(model.hasArtificialVoiceControls)

        model.startVoiceSession()
        try #require(await controlsRecorder.waitForCompleteStartCall())
        #expect(await voice.hasPendingStart)
        #expect(model.canSimulateUserSpeechStarted == false)

        await controlsRecorder.allowCompleteStart()
        try #require(await waitUntilCurrent { model.assistantState == .speaking })
        #expect(await controlsRecorder.completeStartCallCount == 1)
        #expect(model.canSimulateUserSpeechStarted)

        model.simulateUserSpeechStarted()
        try #require(await waitUntilCurrent { model.assistantState == .listening })
        model.simulateUserSpeechEnded()
        try #require(await waitUntilCurrent { model.assistantState == .thinking })
        model.simulateResponseReady()
        try #require(await waitUntilCurrent { model.assistantState == .speaking })
    }

    @Test("Mock pending startup cancellation remains retryable and does not route setup")
    func pendingStartupCancellationRemainsRetryable() async throws {
        let hardware = MockHardwareControlPort()
        let identity = MockIdentityRecognitionAdapter()
        let voice = MockVoiceSessionPort()
        let controlsRecorder = MockControlsRecorder(voice: voice)
        let routing = RoutingRecorder()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voiceSimulationControls: controlsRecorder.controls(),
            onAuthorizationRequired: {
                routing.recordRequest()
            }
        )

        try await moveToGreeting(model: model, hardware: hardware)
        model.startVoiceSession()
        try #require(await controlsRecorder.waitForCompleteStartCall())
        #expect(await voice.hasPendingStart)

        model.endSession(cause: .timeout)
        try #require(await waitUntilCurrent {
            if case .returningHome = model.pendingAction { return true }
            return false
        })
        #expect(await voice.hasPendingStart == false)
        #expect(model.errorMessage == nil)
        #expect(routing.requested == 0)

        await controlsRecorder.allowCompleteStart()
        model.completeReturnHome()
        try #require(await waitUntilCurrent { model.assistantState == .idle })
        #expect(model.errorMessage == nil)
    }

    @Test("Mock startup failure keeps exact generic retry copy and can retry")
    func mockStartupFailureKeepsRetryCopyAndRetryability() async throws {
        let hardware = MockHardwareControlPort()
        let identity = MockIdentityRecognitionAdapter()
        let voice = MockVoiceSessionPort()
        let controlsRecorder = MockControlsRecorder(voice: voice)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voiceSimulationControls: controlsRecorder.controls()
        )

        try await moveToGreeting(model: model, hardware: hardware)
        model.startVoiceSession()
        try #require(await controlsRecorder.waitForCompleteStartCall())
        #expect(await voice.hasPendingStart)
        await voice.failStart(with: TestVoiceFailure.injected)
        await controlsRecorder.allowCompleteStart()

        try #require(await waitUntilCurrent {
            model.errorMessage == "語音啟動失敗，請再試一次。"
        })
        #expect(model.pendingAction == nil)
        #expect(model.hasArtificialVoiceControls)

        await controlsRecorder.resetCompleteStartGate()
        model.startVoiceSession()
        try #require(await controlsRecorder.waitForCompleteStartCall())
        await controlsRecorder.allowCompleteStart()
        try #require(await waitUntilCurrent { model.assistantState == .speaking })
    }

    @Test("Live mode awaits the coordinator without artificial voice controls")
    func liveModeAwaitsCoordinatorWithoutMockControls() async throws {
        let hardware = MockHardwareControlPort()
        let identity = MockIdentityRecognitionAdapter()
        let voice = ImmediateVoiceSessionPort()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voiceSimulationControls: nil
        )

        try await moveToGreeting(model: model, hardware: hardware)
        #expect(model.hasArtificialVoiceControls == false)
        #expect(model.canSimulateUserSpeechStarted == false)
        #expect(model.canSimulateUserSpeechEnded == false)
        #expect(model.canSimulateResponseReady == false)
        #expect(model.canSimulateVoiceFailure == false)

        model.startVoiceSession()
        await voice.waitForStartCall()
        try #require(await waitUntilCurrent { model.assistantState == .speaking })
        #expect(await voice.startCallCount == 1)
    }

    @Test("Automatic identity mode recognizes a known member and starts returning-member voice")
    func automaticIdentityStartsReturningMemberVoice() async throws {
        let hardware = MockHardwareControlPort()
        let memberID = try MemberID(rawValue: "tony")
        let confidence = try RecognitionConfidence(value: 0.78)
        let identity = ImmediateIdentityRecognitionPort(
            result: .known(memberID: memberID, confidence: confidence)
        )
        let voice = ImmediateVoiceSessionPort()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            voiceSimulationControls: nil,
            memberAddressResolver: { memberID in
                try? VoiceMemberAddress(spokenLabel: memberID.rawValue)
            }
        )

        try await moveToRecognizing(model: model, hardware: hardware)
        #expect(model.hasManualIdentityControls == false)
        model.recognizeVisitor()

        try #require(await waitUntilCurrent {
            model.assistantState == .greeting && model.pendingAction == nil
        })
        #expect(model.visitorGreeting == "tony，歡迎回來～")
        #expect(await identity.callCount == 1)

        model.startVoiceSession()
        try #require(await waitUntilCurrent { model.assistantState == .speaking })
        #expect(await voice.startContexts == [.returningMember])
    }

    @Test("Automatic known identity without an approved address stays anonymous")
    func automaticIdentityWithoutAddressStaysAnonymous() async throws {
        let hardware = MockHardwareControlPort()
        let memberID = try MemberID(rawValue: "private-member-id")
        let confidence = try RecognitionConfidence(value: 0.78)
        let identity = ImmediateIdentityRecognitionPort(
            result: .known(memberID: memberID, confidence: confidence)
        )
        let voice = ImmediateVoiceSessionPort()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            voiceSimulationControls: nil
        )

        try await moveToRecognizing(model: model, hardware: hardware)
        model.recognizeVisitor()

        try #require(await waitUntilCurrent {
            model.assistantState == .greeting && model.pendingAction == nil
        })
        #expect(model.visitorGreeting == "歡迎回來～")
    }

    @Test("Automatic identity mode keeps an unknown visitor on generic voice")
    func automaticIdentityStartsVisitorVoiceForUnknown() async throws {
        let hardware = MockHardwareControlPort()
        let identity = ImmediateIdentityRecognitionPort(result: .unknown)
        let voice = ImmediateVoiceSessionPort()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            voiceSimulationControls: nil
        )

        try await moveToRecognizing(model: model, hardware: hardware)
        model.recognizeVisitor()

        try #require(await waitUntilCurrent {
            model.assistantState == .greeting && model.pendingAction == nil
        })
        #expect(model.visitorGreeting == "嗨，歡迎妳！")

        model.startVoiceSession()
        try #require(await waitUntilCurrent { model.assistantState == .speaking })
        #expect(await voice.startContexts == [.visitor])
    }

    @Test("continuous experience recognizes, greets, and starts voice without manual controls")
    func continuousExperienceGreetsAutomatically() async throws {
        let hardware = MockHardwareControlPort()
        let memberID = try MemberID(rawValue: "ruby")
        let identity = ImmediateIdentityRecognitionPort(
            result: .known(
                memberID: memberID,
                confidence: try RecognitionConfidence(value: 0.82)
            )
        )
        let voice = ImmediateVoiceSessionPort()
        let presence = ControlledVisitorPresenceMonitor()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            voiceSimulationControls: nil,
            memberAddressResolver: { candidate in
                candidate == memberID
                    ? try? VoiceMemberAddress(spokenLabel: "Ruby")
                    : nil
            },
            visitorPresenceMonitor: presence
        )

        model.startContinuousExperience()
        await presence.waitForArrivalRequest()
        await presence.signalArrival()

        try #require(await waitUntilCurrent {
            model.assistantState == .speaking
        })
        #expect(model.visitorGreeting == "Ruby，歡迎回來～")
        #expect(await identity.callCount == 1)
        #expect(await voice.startContexts == [.returningMember])
        #expect(model.isContinuousExperienceRunning)
    }

    @Test("ten-second departure result ends the session and rearms recognition")
    func continuousExperienceRearmsAfterDeparture() async throws {
        let hardware = MockHardwareControlPort()
        let identity = ImmediateIdentityRecognitionPort(result: .unknown)
        let voice = ImmediateVoiceSessionPort()
        let presence = ControlledVisitorPresenceMonitor()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            voiceSimulationControls: nil,
            visitorPresenceMonitor: presence
        )

        model.startContinuousExperience()
        await presence.waitForArrivalRequest()
        await presence.signalArrival()
        try #require(await waitUntilCurrent { model.assistantState == .speaking })
        await presence.waitForDepartureRequest()
        await presence.signalDeparture()

        try #require(await waitUntilCurrent { model.assistantState == .idle })
        await presence.waitForArrivalRequest(count: 2)
        #expect(await voice.startContexts == [.visitor])
        #expect(await hardware.returnHomeCallCount == 1)
    }

    @Test("a stopped continuous generation cannot clear a freshly restarted loop")
    func stoppedContinuousGenerationCannotClearRestart() async throws {
        let hardware = MockHardwareControlPort()
        let identity = ImmediateIdentityRecognitionPort(result: .unknown)
        let voice = ImmediateVoiceSessionPort()
        let presence = DeferredStopVisitorPresenceMonitor()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            voiceSimulationControls: nil,
            visitorPresenceMonitor: presence
        )

        model.startContinuousExperience()
        await presence.waitForArrivalRequest(count: 1)
        model.stopContinuousExperience()
        model.startContinuousExperience()
        await presence.waitForArrivalRequest(count: 2)

        await presence.releaseFirstArrivalAsCancellation()
        await presence.waitForStopCall(count: 2)
        for _ in 0..<32 { await Task.yield() }
        #expect(model.isContinuousExperienceRunning)

        model.stopContinuousExperience()
        await presence.releaseAllArrivalsAsCancellation()
    }

    @Test("continuous restart waits for presence teardown before a new visitor wait")
    func continuousRestartWaitsForPresenceTeardown() async throws {
        let source = SerializedRestartPresenceSource()
        let presence = PilotVisitorPresenceMonitor(
            source: source,
            departureAbsenceDuration: .seconds(10)
        )
        let hardware = MockHardwareControlPort()
        let identity = ImmediateIdentityRecognitionPort(result: .unknown)
        let voice = ImmediateVoiceSessionPort()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            voiceSimulationControls: nil,
            visitorPresenceMonitor: presence
        )

        model.startContinuousExperience()
        await source.waitForCapture(count: 1)

        model.stopContinuousExperience()
        model.startContinuousExperience()
        await source.waitForStopCall(count: 1)

        for _ in 0..<128 { await Task.yield() }
        #expect(await source.captureCount == 1)
        #expect(await source.startCount == 1)

        await source.releaseFirstStop()
        #expect(await source.waitForStart(count: 2))

        #expect(await source.captureCount == 2)
        #expect(await source.startCount == 2)
        #expect(await source.overlapDetected == false)

        model.stopContinuousExperience()
        await source.releaseAllCapturesAsCancellation()
    }

    @Test("automatic departure failure returns home before offering retry")
    func continuousDepartureFailureReturnsHome() async throws {
        let hardware = MockHardwareControlPort()
        let identity = ImmediateIdentityRecognitionPort(result: .unknown)
        let voice = ImmediateVoiceSessionPort()
        let presence = ControlledVisitorPresenceMonitor()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            voiceSimulationControls: nil,
            visitorPresenceMonitor: presence
        )

        model.startContinuousExperience()
        await presence.waitForArrivalRequest()
        await presence.signalArrival()
        try #require(await waitUntilCurrent { model.assistantState == .speaking })
        await presence.waitForDepartureRequest()
        let stopped = Task { @MainActor in
            for await running in model.$isContinuousExperienceRunning.values {
                if !running { return }
            }
        }
        await presence.failDeparture()
        await presence.waitForStopCall()
        await stopped.value

        #expect(model.errorMessage != nil)
        #expect(model.assistantState == .idle)
        #expect(await hardware.returnHomeCallCount == 1)
    }

    @Test("Authorization-required startup invokes routing exactly once")
    func authorizationRequiredRoutesExactlyOnce() async throws {
        let hardware = MockHardwareControlPort()
        let identity = MockIdentityRecognitionAdapter()
        let voice = ImmediateVoiceSessionPort(startBehavior: .authorizationRequired)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let routing = RoutingRecorder()
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voiceSimulationControls: nil,
            onAuthorizationRequired: {
                routing.recordRequest()
            }
        )

        try await moveToGreeting(model: model, hardware: hardware)
        model.startVoiceSession()

        await voice.waitForStartCall()
        try #require(await waitUntilCurrent { routing.requested > 0 })
        #expect(routing.requested == 1)
        #expect(model.errorMessage == nil)
        #expect(model.assistantState == .greeting)
    }

    @Test("Active authorization-required event routes setup exactly once")
    func activeAuthorizationRequiredRoutesExactlyOnce() async throws {
        let hardware = MockHardwareControlPort()
        let identity = MockIdentityRecognitionAdapter()
        let voice = ImmediateVoiceSessionPort()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let routing = RoutingRecorder()
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voiceSimulationControls: nil,
            onAuthorizationRequired: {
                routing.recordRequest()
            }
        )

        try await moveToGreeting(model: model, hardware: hardware)
        model.startVoiceSession()
        await voice.waitForStartCall()
        try #require(await waitUntilCurrent { model.assistantState == .speaking })

        await voice.emit(.authorizationRequired)
        try #require(await waitUntilCurrent { routing.requested > 0 })
        #expect(routing.requested == 1)
        #expect(model.assistantState == .speaking)
        #expect(model.errorMessage == nil)

        await voice.emit(.authorizationRequired)
        try #require(await waitUntilCurrent { routing.requested > 1 })
        #expect(routing.requested == 2)
    }

    @Test("Ordinary startup failure keeps generic retry and never routes setup")
    func ordinaryStartupFailureDoesNotRouteSetup() async throws {
        let hardware = MockHardwareControlPort()
        let identity = MockIdentityRecognitionAdapter()
        let voice = ImmediateVoiceSessionPort(startBehavior: .ordinaryFailure)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let routing = RoutingRecorder()
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voiceSimulationControls: nil,
            onAuthorizationRequired: {
                routing.recordRequest()
            }
        )

        try await moveToGreeting(model: model, hardware: hardware)
        model.startVoiceSession()

        await voice.waitForStartCall()
        try #require(await waitUntilCurrent {
            model.errorMessage == "語音啟動失敗，請再試一次。"
        })
        #expect(routing.requested == 0)
        #expect(model.assistantState == .greeting)
    }
}

@MainActor
private func moveToGreeting(
    model: SessionSimulationModel,
    hardware: MockHardwareControlPort
) async throws {
    model.confirm(direction: .center)
    try #require(await waitUntilCurrent {
        model.assistantState == .detected(direction: .center) && model.pendingAction == nil
    })

    model.begin()
    try #require(await waitUntilCurrent { model.assistantState == .rotating })
    #expect(model.canCompleteRotation)
    model.completeArrival()
    try #require(await waitUntilCurrent {
        model.assistantState == .recognizing && model.pendingAction == nil
    })

    model.resolveVisitor(.unknown)
    try #require(await waitUntilCurrent {
        model.assistantState == .greeting && model.pendingAction == nil
    })
}

@MainActor
private func moveToRecognizing(
    model: SessionSimulationModel,
    hardware: MockHardwareControlPort
) async throws {
    model.confirm(direction: .center)
    try #require(await waitUntilCurrent {
        model.assistantState == .detected(direction: .center) && model.pendingAction == nil
    })

    model.begin()
    try #require(await waitUntilCurrent { model.assistantState == .rotating })
    model.completeArrival()
    try #require(await waitUntilCurrent {
        model.assistantState == .recognizing && model.pendingAction == nil
    })
}

@MainActor
private func waitUntilCurrent(
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    // The full App test target runs multiple Swift Testing suites in parallel.
    // Keep this bounded while allowing the coordinator and its state-stream
    // consumer enough executor turns under that load.
    for _ in 0..<4_096 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

private enum TestVoiceFailure: Error, Equatable, Sendable {
    case injected
}

@MainActor
private final class RoutingRecorder {
    var requested = 0

    func recordRequest() {
        requested += 1
    }
}

private actor MockControlsRecorder {
    private let voice: MockVoiceSessionPort
    private let completeStartCallContinuation: AsyncStream<Void>.Continuation
    private var completeStartCallIterator: AsyncStream<Void>.Iterator
    private(set) var completeStartCallCount = 0
    private var completeStartGateContinuation: CheckedContinuation<Void, Never>?
    private var completeStartGateIsOpen = false

    init(voice: MockVoiceSessionPort) {
        self.voice = voice
        let completeStartCall = AsyncStream<Void>.makeStream(
            of: Void.self,
            bufferingPolicy: .unbounded
        )
        self.completeStartCallContinuation = completeStartCall.continuation
        self.completeStartCallIterator = completeStartCall.stream.makeAsyncIterator()
    }

    nonisolated func controls() -> VoiceSimulationControls {
        let recorder = self
        return VoiceSimulationControls(
            hasPendingStart: {
                await recorder.hasPendingStart()
            },
            completeStart: {
                await recorder.completeStart()
            },
            emit: { event in
                await recorder.emit(event)
            }
        )
    }

    func waitForCompleteStartCall() async -> Bool {
        var iterator = completeStartCallIterator
        let event: Void? = await iterator.next()
        completeStartCallIterator = iterator
        return event != nil
    }

    func allowCompleteStart() {
        completeStartGateIsOpen = true
        completeStartGateContinuation?.resume()
        completeStartGateContinuation = nil
    }

    func resetCompleteStartGate() {
        completeStartGateIsOpen = false
        completeStartCallCount = 0
    }

    private func hasPendingStart() async -> Bool {
        await voice.hasPendingStart
    }

    private func completeStart() async {
        completeStartCallCount += 1
        completeStartCallContinuation.yield(())
        if !completeStartGateIsOpen {
            await withCheckedContinuation { continuation in
                if completeStartGateIsOpen {
                    continuation.resume()
                } else {
                    completeStartGateContinuation = continuation
                }
            }
        }
        await voice.completeStart()
    }

    private func emit(_ event: VoiceSessionEvent) async {
        await voice.emit(event)
    }
}

private actor ImmediateVoiceSessionPort: VoiceSessionPort {
    enum StartBehavior: Sendable {
        case success
        case authorizationRequired
        case ordinaryFailure
    }

    private let startBehavior: StartBehavior
    private(set) var startCallCount = 0
    private(set) var startContexts: [VoiceContext] = []
    private var continuation: AsyncStream<VoiceSessionEvent>.Continuation?
    private var startCallWaiters: [CheckedContinuation<Void, Never>] = []

    init(startBehavior: StartBehavior = .success) {
        self.startBehavior = startBehavior
    }

    func start(context: VoiceContext) async throws {
        startCallCount += 1
        startContexts.append(context)
        let waiters = startCallWaiters
        startCallWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        switch startBehavior {
        case .success:
            return
        case .authorizationRequired:
            throw VoiceSessionAuthorizationError.authorizationRequired
        case .ordinaryFailure:
            throw TestVoiceFailure.injected
        }
    }

    func waitForStartCall() async {
        if startCallCount > 0 { return }
        await withCheckedContinuation { waiter in
            if startCallCount > 0 {
                waiter.resume()
            } else {
                startCallWaiters.append(waiter)
            }
        }
    }

    func eventUpdates() async -> AsyncStream<VoiceSessionEvent> {
        let pair = AsyncStream<VoiceSessionEvent>.makeStream(
            of: VoiceSessionEvent.self,
            bufferingPolicy: .unbounded
        )
        continuation = pair.continuation
        return pair.stream
    }

    func emit(_ event: VoiceSessionEvent) {
        continuation?.yield(event)
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }
}

private actor ImmediateIdentityRecognitionPort: IdentityRecognitionPort {
    private let result: RecognitionResult
    private(set) var callCount = 0

    init(result: RecognitionResult) {
        self.result = result
    }

    func recognizeCurrentVisitor() async throws -> RecognitionResult {
        callCount += 1
        return result
    }
}

private actor ControlledVisitorPresenceMonitor: VisitorPresenceMonitoringPort {
    private var arrivalContinuation: CheckedContinuation<Void, Error>?
    private var departureContinuation: CheckedContinuation<Void, Error>?
    private var arrivalRequestCount = 0
    private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var departureWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopCallCount = 0
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForVisitor() async throws {
        arrivalRequestCount += 1
        let ready = arrivalWaiters.filter { arrivalRequestCount >= $0.0 }
        arrivalWaiters.removeAll { arrivalRequestCount >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        try await withCheckedThrowingContinuation { arrivalContinuation = $0 }
    }

    func waitForDeparture() async throws {
        for waiter in departureWaiters { waiter.resume() }
        departureWaiters.removeAll()
        try await withCheckedThrowingContinuation { departureContinuation = $0 }
    }

    func stop() async {
        stopCallCount += 1
        let ready = stopWaiters
        stopWaiters.removeAll()
        for waiter in ready { waiter.resume() }
        arrivalContinuation?.resume(throwing: CancellationError())
        arrivalContinuation = nil
        departureContinuation?.resume(throwing: CancellationError())
        departureContinuation = nil
    }

    func waitForArrivalRequest(count: Int = 1) async {
        if arrivalRequestCount >= count { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    func waitForDepartureRequest() async {
        if departureContinuation != nil { return }
        await withCheckedContinuation { departureWaiters.append($0) }
    }

    func waitForStopCall() async {
        if stopCallCount > 0 { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    func signalArrival() {
        arrivalContinuation?.resume()
        arrivalContinuation = nil
    }

    func signalDeparture() {
        departureContinuation?.resume()
        departureContinuation = nil
    }

    func failDeparture() {
        departureContinuation?.resume(throwing: TestVoiceFailure.injected)
        departureContinuation = nil
    }
}

private actor DeferredStopVisitorPresenceMonitor: VisitorPresenceMonitoringPort {
    private var arrivalContinuations: [CheckedContinuation<Void, Error>] = []
    private var arrivalRequestCount = 0
    private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var stopCallCount = 0
    private var stopWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func waitForVisitor() async throws {
        arrivalRequestCount += 1
        let ready = arrivalWaiters.filter { arrivalRequestCount >= $0.0 }
        arrivalWaiters.removeAll { arrivalRequestCount >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        try await withCheckedThrowingContinuation {
            arrivalContinuations.append($0)
        }
    }

    func waitForDeparture() async throws {
        throw CancellationError()
    }

    func stop() async {
        stopCallCount += 1
        let ready = stopWaiters.filter { stopCallCount >= $0.0 }
        stopWaiters.removeAll { stopCallCount >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
    }

    func waitForArrivalRequest(count: Int) async {
        if arrivalRequestCount >= count { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    func waitForStopCall(count: Int) async {
        if stopCallCount >= count { return }
        await withCheckedContinuation { stopWaiters.append((count, $0)) }
    }

    func releaseFirstArrivalAsCancellation() {
        guard !arrivalContinuations.isEmpty else { return }
        arrivalContinuations.removeFirst().resume(throwing: CancellationError())
    }

    func releaseAllArrivalsAsCancellation() {
        let continuations = arrivalContinuations
        arrivalContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }
}

private actor SerializedRestartPresenceSource: PilotVisitorPresenceEvidenceSource {
    private var cameraRunning = false
    private var captureInProgress = false
    private var firstStopReleased = false
    private var firstStopContinuations: [CheckedContinuation<Void, Never>] = []
    private var captureContinuations: [CheckedContinuation<Bool, Error>] = []
    private var captureWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var stopWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    private(set) var startCount = 0
    private(set) var captureCount = 0
    private(set) var stopCallCount = 0
    private(set) var overlapDetected = false

    func startCamera() async throws {
        guard !cameraRunning else {
            overlapDetected = true
            throw SerializedRestartPresenceSourceError.overlap
        }
        cameraRunning = true
        startCount += 1
    }

    func stopCamera() async {
        stopCallCount += 1
        let ready = stopWaiters.filter { stopCallCount >= $0.0 }
        stopWaiters.removeAll { stopCallCount >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }

        if !firstStopReleased {
            await withCheckedContinuation {
                firstStopContinuations.append($0)
            }
        }

        cameraRunning = false
        let captures = captureContinuations
        captureContinuations.removeAll()
        for continuation in captures {
            continuation.resume(throwing: CancellationError())
        }
    }

    func captureUsableFace() async throws -> Bool {
        guard cameraRunning, !captureInProgress else {
            overlapDetected = true
            throw SerializedRestartPresenceSourceError.overlap
        }
        captureInProgress = true
        captureCount += 1
        let ready = captureWaiters.filter { captureCount >= $0.0 }
        captureWaiters.removeAll { captureCount >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        defer { captureInProgress = false }

        return try await withCheckedThrowingContinuation {
            captureContinuations.append($0)
        }
    }

    func waitForCapture(count: Int) async {
        if captureCount >= count { return }
        await withCheckedContinuation {
            captureWaiters.append((count, $0))
        }
    }

    func waitForStart(count: Int, timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while startCount < count {
            if ContinuousClock.now >= deadline { return false }
            await Task.yield()
        }
        return true
    }

    func waitForStopCall(count: Int) async {
        if stopCallCount >= count { return }
        await withCheckedContinuation {
            stopWaiters.append((count, $0))
        }
    }

    func releaseFirstStop() {
        firstStopReleased = true
        let continuations = firstStopContinuations
        firstStopContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func releaseAllCapturesAsCancellation() {
        let continuations = captureContinuations
        captureContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }
}

private enum SerializedRestartPresenceSourceError: Error {
    case overlap
}
