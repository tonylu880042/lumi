import LumiDomain
import LumiApplication
import LumiInfrastructure
import Testing
@testable import LumiApp

@MainActor
@Suite("Session simulation dual-mode wrapper", .serialized)
struct SessionSimulationModelTests {
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
        try #require(await waitUntilAsync { await voice.startCallCount > 0 })
        try #require(await waitUntilCurrent { model.assistantState == .speaking })
        #expect(await voice.startCallCount == 1)
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

        try #require(await waitUntilAsync { await voice.startCallCount > 0 })
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
        try #require(await waitUntilAsync { await voice.startCallCount > 0 })
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

        try #require(await waitUntilAsync { await voice.startCallCount > 0 })
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
private func waitUntilCurrent(
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<128 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

private func waitUntilAsync(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<128 {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
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
        let event = await iterator.next()
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
    private var continuation: AsyncStream<VoiceSessionEvent>.Continuation?

    init(startBehavior: StartBehavior = .success) {
        self.startBehavior = startBehavior
    }

    func start(context: VoiceContext) async throws {
        startCallCount += 1
        switch startBehavior {
        case .success:
            return
        case .authorizationRequired:
            throw VoiceSessionAuthorizationError.authorizationRequired
        case .ordinaryFailure:
            throw TestVoiceFailure.injected
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
