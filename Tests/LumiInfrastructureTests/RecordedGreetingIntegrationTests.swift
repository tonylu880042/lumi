import Foundation
import LumiApplication
import LumiDomain
@testable import LumiInfrastructure
import Testing

@Suite("Recorded greeting selection and Realtime integration")
struct RecordedGreetingIntegrationTests {
    @Test("arrival and eligible departure replace the recording without replay on reconnect",
          arguments: [false, true])
    func departureReplacesWelcomeAndDoesNotReplay(isArrival: Bool) async throws {
        let first = Date(timeIntervalSince1970: 1_790_902_800)
        let transport = GreetingRealtimeTransport()
        let reconnect = GreetingRealtimeTransport()
        let greeting = ControlledGreetingPlayer()
        let source = GreetingSecretSource()
        let adapter = OpenAIRealtimeAdapter(
            configuration: OpenAIRealtimeConfiguration(usesExternalGreeting: true),
            clientSecretSource: source,
            transportFactory: GreetingTransportFactory(transports: [transport, reconnect]),
            recordedGreeting: greeting, now: { first.addingTimeInterval(1800) }
        )
        let stream = await adapter.eventUpdates()
        let events = ClosingEventLog()
        let collector = Task { for await event in stream { await events.append(event) } }
        let start = Task {
            try await adapter.start(
                context: .returningMember, direction: .general, memberAddress: nil,
                memoryContext: VoiceMemberMemoryContext(
                    highlight: nil, departureWeeklyMeetingDayCount: isArrival ? nil : 3,
                    departureFirstMeetingAt: isArrival ? nil : first,
                    arrivalWeeklyMeetingDayCount: isArrival ? 3 : nil,
                    arrivalEncounterAt: isArrival ? first.addingTimeInterval(1800) : nil
                )
            )
        }
        await transport.waitForConnect()
        await transport.emit(.sessionCreated)
        try await start.value
        let configuration = try #require(await source.receivedConfigurations.first)
        #expect(!configuration.usesExternalGreeting)
        #expect(configuration.instructions.contains(isArrival
            ? "這週已經見到你 3 次" : "這週已經來 3 次"))
        #expect(!configuration.instructions.contains("1790902800"))
        #expect(!configuration.instructions.contains("30 分鐘"))
        #expect(await greeting.contexts.isEmpty)

        await transport.emit(.outputAudioStarted)
        await transport.emit(.outputAudioStopped)
        try #require(await waitFor { await events.count(.greetingCompleted) == 1 })
        await transport.finishUnexpectedly()
        try #require(await waitFor { await reconnect.connectCallCount == 1 })
        #expect(await reconnect.connectionPurposes == [.reconnect])
        await reconnect.emit(.sessionCreated)
        await reconnect.emit(.outputAudioStarted)
        await reconnect.emit(.outputAudioStopped)
        try #require(await waitFor { await events.count(.assistantOutputEnded) == 2 })
        #expect(await events.count(.greetingCompleted) == 1)
        #expect(await greeting.contexts.isEmpty)
        await adapter.stop()
        collector.cancel()
        await collector.value
    }

    @Test("conversational farewell never assumes the visitor is leaving the store")
    func conversationalFarewellAlwaysUsesGenericClip() async throws {
        let player = ControlledRecordedVoicePlayer()
        let coordinator = RecordedGreetingCoordinator(
            playback: RecordedVoicePlayback(player: player), vitalityProvider: { .calm }
        )
        for _ in 0 ..< 2 {
            let task = Task { try await coordinator.playGoodbye() }
            await player.waitForPlay()
            await player.finish()
            try await task.value
        }
        #expect(await player.played == [.goodbye07, .goodbye07])
    }

    @Test("local farewell provides the response-ready transition before speaking")
    func farewellMovesThinkingToSpeaking() async throws {
        let fixture = try await readyForClosing()
        await fixture.requestClosing()
        try #require(await waitFor { await fixture.greeting.goodbyeCount == 1 })
        #expect(await fixture.events.contains(.responseReady))
        await fixture.stop()
    }

    @Test("visitor and returning contexts map vitality to distinct validated clip groups")
    func selectionSeparatesKnownAndUnknownContexts() {
        var selector = RecordedGreetingSelector()

        #expect(selector.select(context: .visitor, vitality: .calm) == .welcome01)
        #expect(selector.select(context: .visitor, vitality: .happy) == .welcome02)
        #expect(selector.select(context: .visitor, vitality: .excited) == .welcome03)
        #expect(selector.select(context: .returningMember, vitality: .calm) == .returning04)
        #expect(selector.select(context: .returningMember, vitality: .happy) == .returning05)
        #expect(selector.select(context: .returningMember, vitality: .excited) == .returning06)
    }

    @Test("repeating the same vitality rotates within its greeting class")
    func selectionDoesNotRepeatAClipInTheSameClass() {
        var selector = RecordedGreetingSelector()

        let visitorClips = (0 ..< 3).map { _ in
            selector.select(context: .visitor, vitality: .calm)
        }
        let returningClips = (0 ..< 3).map { _ in
            selector.select(context: .returningMember, vitality: .excited)
        }

        #expect(visitorClips.count == 3)
        #expect(visitorClips.contains(.welcome01))
        #expect(visitorClips.contains(.welcome02))
        #expect(visitorClips.contains(.welcome03))
        #expect(returningClips.count == 3)
        #expect(returningClips.contains(.returning04))
        #expect(returningClips.contains(.returning05))
        #expect(returningClips.contains(.returning06))
        #expect(zip(visitorClips, visitorClips.dropFirst()).allSatisfy { $0 != $1 })
        #expect(zip(returningClips, returningClips.dropFirst()).allSatisfy { $0 != $1 })
    }

    @Test("goodbye selection is available without an automatic trigger")
    func goodbyeSelectionRotatesItsTwoClips() {
        var selector = RecordedGreetingSelector()

        #expect(selector.selectGoodbye() == .goodbye07)
        #expect(selector.selectGoodbye() == .goodbye08)
    }

    @Test("an explicit post-greeting closing plays one local goodbye and emits a lifecycle request")
    func explicitClosingPlaysGoodbyeOnceAfterAUserTurn() async throws {
        let transport = GreetingRealtimeTransport()
        let greeting = ControlledGreetingPlayer()
        let adapter = makeAdapter(
            transports: [transport],
            greeting: greeting,
            configuration: OpenAIRealtimeConfiguration(
                usesExternalGreeting: true,
                allowsConversationClosing: true
            )
        )
        let events = await adapter.eventUpdates()

        let start = Task { try await adapter.start(context: .visitor) }
        await transport.waitForConnect()
        await transport.emit(.sessionCreated)
        try await start.value
        await greeting.waitForPlay()
        #expect(await nextVoiceEvent(from: events) == .assistantOutputStarted)
        await greeting.finish()
        #expect(await nextVoiceEvent(from: events) == .assistantOutputEnded)
        #expect(await waitFor { await transport.mediaEnabledHistory == [true] })
        #expect(await nextVoiceEvent(from: events) == .greetingCompleted)

        // The transport emits this only for an accepted post-greeting turn.
        await transport.emit(.inputAudioSpeechStarted)
        #expect(await nextVoiceEvent(from: events) == .userSpeechStarted)
        await transport.emit(
            .toolCall(
                VoiceToolCall(callID: "closing-call", kind: .endConversation)
            )
        )
        await greeting.waitForGoodbye()
        #expect(await greeting.goodbyeCount == 1)
        #expect(await nextVoiceEvent(from: events) == .responseReady)
        #expect(await nextVoiceEvent(from: events) == .assistantOutputStarted)
        await greeting.finishGoodbye()
        #expect(await nextVoiceEvent(from: events) == .assistantOutputEnded)
        #expect(await nextVoiceEvent(from: events) == .conversationEndRequested)
        #expect(await transport.mediaEnabledHistory == [true, false])

        // A duplicate provider call during the same generation cannot replay
        // the local farewell.
        await transport.emit(
            .toolCall(
                VoiceToolCall(callID: "closing-call-duplicate", kind: .endConversation)
            )
        )
        await Task.yield()
        #expect(await greeting.goodbyeCount == 1)

        await adapter.stop()
    }

    @Test("a closing tool before the first user turn is ignored")
    func closingBeforePostGreetingTurnDoesNotEndSession() async throws {
        let transport = GreetingRealtimeTransport()
        let greeting = ControlledGreetingPlayer()
        let adapter = makeAdapter(
            transports: [transport],
            greeting: greeting,
            configuration: OpenAIRealtimeConfiguration(
                usesExternalGreeting: true,
                allowsConversationClosing: true
            )
        )

        let start = Task { try await adapter.start(context: .visitor) }
        await transport.waitForConnect()
        await transport.emit(.sessionCreated)
        try await start.value
        await greeting.waitForPlay()
        await greeting.finish()
        #expect(await waitFor { await transport.mediaEnabledHistory == [true] })
        await transport.emit(
            .toolCall(
                VoiceToolCall(callID: "premature-closing", kind: .endConversation)
            )
        )
        await Task.yield()

        #expect(await greeting.goodbyeCount == 0)
        #expect(await transport.mediaEnabledHistory == [true])
        await adapter.stop()
    }

    @Test("failed microphone gating skips farewell and still requests session end")
    func failedClosingMediaGateEndsWithoutPlayback() async throws {
        let fixture = try await readyForClosing()
        await fixture.transport.failMediaDisable()
        await fixture.requestClosing()
        #expect(await waitFor { await fixture.events.contains(.conversationEndRequested) })
        #expect(await fixture.greeting.goodbyeCount == 0)
        await fixture.stop()
    }

    @Test("disconnect during farewell ends once without reconnecting")
    func disconnectDuringFarewellDoesNotReconnect() async throws {
        let reconnect = GreetingRealtimeTransport()
        let fixture = try await readyForClosing(reconnect: reconnect)
        await fixture.requestClosing()
        try #require(await waitFor { await fixture.greeting.goodbyeCount == 1 })
        await fixture.transport.finishUnexpectedly()
        #expect(await waitFor { await fixture.events.contains(.conversationEndRequested) })
        #expect(await reconnect.connectCallCount == 0)
        #expect(await fixture.greeting.goodbyeCount == 1)
        await fixture.stop()
    }

    @Test("failed farewell playback ends the session once")
    func failedFarewellPlaybackStillEnds() async throws {
        let fixture = try await readyForClosing()
        await fixture.requestClosing()
        try #require(await waitFor { await fixture.greeting.goodbyeCount == 1 })
        await fixture.greeting.failGoodbye()
        #expect(await waitFor { await fixture.events.contains(.conversationEndRequested) })
        #expect(await fixture.events.count(.conversationEndRequested) == 1)
        await fixture.stop()
    }

    @Test("stop during farewell cancels playback without emitting stale completion")
    func stopDuringFarewellDoesNotRequestAnotherEnd() async throws {
        let fixture = try await readyForClosing()
        await fixture.requestClosing()
        try #require(await waitFor { await fixture.greeting.goodbyeCount == 1 })
        await fixture.adapter.stop()
        await fixture.collector.value
        #expect(await fixture.events.count(.conversationEndRequested) == 0)
        #expect(await fixture.transport.closeCallCount == 1)
    }

    @Test("greeting coordinator selects vitality and propagates missing clip failures")
    func coordinatorUsesVitalityAndPropagatesPlaybackFailure() async throws {
        let player = ControlledRecordedVoicePlayer()
        let playback = RecordedVoicePlayback(player: player)
        let coordinator = RecordedGreetingCoordinator(
            playback: playback,
            vitalityProvider: { .happy }
        )
        let task = Task { try await coordinator.play(context: .visitor) }

        await player.waitForPlay()
        #expect(await player.played == [.welcome02])
        await player.finish()
        try await task.value

        let failingPlayback = RecordedVoicePlayback(
            player: FailingRecordedVoicePlayer(error: .invalidResource)
        )
        let failingCoordinator = RecordedGreetingCoordinator(
            playback: failingPlayback,
            vitalityProvider: { .calm }
        )
        await #expect(throws: RecordedVoicePlaybackError.invalidResource) {
            try await failingCoordinator.play(context: .visitor)
        }
    }

    @Test("initial local greeting starts asynchronously and enables input only after it ends")
    func initialGreetingLifecycle() async throws {
        let transport = GreetingRealtimeTransport()
        let greeting = ControlledGreetingPlayer()
        let adapter = makeAdapter(
            transports: [transport],
            greeting: greeting,
            configuration: OpenAIRealtimeConfiguration(usesExternalGreeting: true)
        )
        let events = await adapter.eventUpdates()

        let start = Task { try await adapter.start(context: .visitor) }
        await transport.waitForConnect()
        await transport.emit(.sessionCreated)
        try await start.value
        await greeting.waitForPlay()

        #expect(await greeting.contexts == [.visitor])
        #expect(await nextVoiceEvent(from: events) == .assistantOutputStarted)
        #expect(await transport.mediaEnabledHistory.isEmpty)

        await greeting.finish()
        #expect(await nextVoiceEvent(from: events) == .assistantOutputEnded)
        #expect(await waitFor { await transport.mediaEnabledHistory == [true] })
        #expect(await nextVoiceEvent(from: events) == .greetingCompleted)

        await adapter.stop()
    }

    @Test("stopping local greeting cancels its generation without re-enabling input")
    func stoppingLocalGreetingCancelsWithoutReactivation() async throws {
        let transport = GreetingRealtimeTransport()
        let greeting = ControlledGreetingPlayer()
        let adapter = makeAdapter(
            transports: [transport],
            greeting: greeting,
            configuration: OpenAIRealtimeConfiguration(usesExternalGreeting: true)
        )
        let events = await adapter.eventUpdates()

        let start = Task { try await adapter.start(context: .returningMember) }
        await transport.waitForConnect()
        await transport.emit(.sessionCreated)
        try await start.value
        await greeting.waitForPlay()
        #expect(await nextVoiceEvent(from: events) == .assistantOutputStarted)

        await adapter.stop()
        #expect(await greeting.stopCallCount == 1)
        #expect(await transport.mediaEnabledHistory.isEmpty)
        await adapter.stop()
        #expect(await greeting.stopCallCount == 1)
    }

    @Test("a missing local clip publishes a provider-neutral failure after readiness")
    func missingLocalClipPublishesFailure() async throws {
        let transport = GreetingRealtimeTransport()
        let greeting = FailingGreetingPlayer()
        let adapter = makeAdapter(
            transports: [transport],
            greeting: greeting,
            configuration: OpenAIRealtimeConfiguration(usesExternalGreeting: true)
        )
        let events = await adapter.eventUpdates()

        let start = Task { try await adapter.start(context: .visitor) }
        await transport.waitForConnect()
        await transport.emit(.sessionCreated)
        try await start.value
        #expect(await waitFor { await greeting.playCallCount == 1 })
        #expect(await nextVoiceEvent(from: events) == .assistantOutputStarted)
        #expect(await nextVoiceEvent(from: events) == .assistantOutputEnded)
        #expect(await nextVoiceEvent(from: events) == .failure)
        #expect(await transport.mediaEnabledHistory.isEmpty)

        await adapter.stop()
    }

    @Test("disconnecting during local playback stops the old clip before reconnect")
    func disconnectDuringLocalGreetingStopsBeforeReconnect() async throws {
        let firstTransport = GreetingRealtimeTransport()
        let reconnectTransport = GreetingRealtimeTransport()
        let greeting = ControlledGreetingPlayer()
        let adapter = makeAdapter(
            transports: [firstTransport, reconnectTransport],
            greeting: greeting,
            configuration: OpenAIRealtimeConfiguration(usesExternalGreeting: true)
        )
        let events = await adapter.eventUpdates()

        let start = Task { try await adapter.start(context: .visitor) }
        await firstTransport.waitForConnect()
        await firstTransport.emit(.sessionCreated)
        try await start.value
        await greeting.waitForPlay()
        #expect(await nextVoiceEvent(from: events) == .assistantOutputStarted)

        await firstTransport.finishUnexpectedly()
        #expect(await waitFor { await greeting.stopCallCount == 1 })
        #expect(await nextVoiceEvent(from: events) == .assistantOutputEnded)
        #expect(await waitFor { await reconnectTransport.connectCallCount == 1 })
        #expect(await reconnectTransport.connectionPurposes == [.reconnect])
        #expect(await greeting.contexts == [.visitor])

        await reconnectTransport.emit(.sessionCreated)
        await adapter.stop()
    }

    @Test("reconnect keeps the completed local greeting from replaying")
    func reconnectDoesNotReplayLocalGreeting() async throws {
        let firstTransport = GreetingRealtimeTransport()
        let reconnectTransport = GreetingRealtimeTransport()
        let greeting = ControlledGreetingPlayer()
        let adapter = makeAdapter(
            transports: [firstTransport, reconnectTransport],
            greeting: greeting,
            configuration: OpenAIRealtimeConfiguration(usesExternalGreeting: true)
        )
        let events = await adapter.eventUpdates()

        let start = Task { try await adapter.start(context: .visitor) }
        await firstTransport.waitForConnect()
        await firstTransport.emit(.sessionCreated)
        try await start.value
        await greeting.waitForPlay()
        #expect(await nextVoiceEvent(from: events) == .assistantOutputStarted)
        await greeting.finish()
        #expect(await nextVoiceEvent(from: events) == .assistantOutputEnded)
        #expect(await waitFor { await firstTransport.mediaEnabledHistory == [true] })
        #expect(await nextVoiceEvent(from: events) == .greetingCompleted)

        await firstTransport.finishUnexpectedly()
        #expect(await waitFor { await reconnectTransport.connectCallCount == 1 })
        await reconnectTransport.emit(.sessionCreated)
        #expect(await greeting.contexts == [.visitor])
        #expect(await reconnectTransport.mediaEnabledHistory.isEmpty)

        await adapter.stop()
    }

    @Test("a new start cannot race a suspended local-greeting teardown")
    func startIsRejectedUntilLocalGreetingTeardownCompletes() async throws {
        let transport = GreetingRealtimeTransport()
        let greeting = ControlledGreetingPlayer()
        let adapter = makeAdapter(
            transports: [transport],
            greeting: greeting,
            configuration: OpenAIRealtimeConfiguration(usesExternalGreeting: true)
        )

        let start = Task { try await adapter.start(context: .visitor) }
        await transport.waitForConnect()
        await transport.emit(.sessionCreated)
        try await start.value
        await greeting.waitForPlay()

        await greeting.suspendStop()
        let stop = Task { await adapter.stop() }
        #expect(await waitFor { await greeting.stopStarted })

        let racingStart = Task {
            try await adapter.start(context: .returningMember)
        }
        await #expect(throws: OpenAIRealtimeAdapterError.startInProgress) {
            try await racingStart.value
        }

        await greeting.releaseStop()
        await stop.value
        #expect(await greeting.stopCallCount == 1)
    }
}

private struct ClosingFixture {
    let adapter: OpenAIRealtimeAdapter
    let transport: GreetingRealtimeTransport
    let greeting: ControlledGreetingPlayer
    let events: ClosingEventLog
    let collector: Task<Void, Never>

    func requestClosing() async {
        await transport.emit(.toolCall(VoiceToolCall(callID: "end", kind: .endConversation)))
    }

    func stop() async {
        await adapter.stop()
        collector.cancel()
        await collector.value
    }
}

private actor ClosingEventLog {
    private var events: [VoiceSessionEvent] = []
    func append(_ event: VoiceSessionEvent) { events.append(event) }
    func contains(_ event: VoiceSessionEvent) -> Bool { events.contains(event) }
    func count(_ event: VoiceSessionEvent) -> Int { events.filter { $0 == event }.count }
}

private func readyForClosing(reconnect: GreetingRealtimeTransport? = nil) async throws -> ClosingFixture {
    let transport = GreetingRealtimeTransport()
    let greeting = ControlledGreetingPlayer()
    let adapter = makeAdapter(
        transports: [transport] + (reconnect.map { [$0] } ?? []),
        greeting: greeting,
        configuration: OpenAIRealtimeConfiguration(usesExternalGreeting: true, allowsConversationClosing: true)
    )
    let stream = await adapter.eventUpdates()
    let events = ClosingEventLog()
    let collector = Task { for await event in stream { await events.append(event) } }
    let start = Task { try await adapter.start(context: .visitor) }
    await transport.waitForConnect()
    await transport.emit(.sessionCreated)
    try await start.value
    await greeting.waitForPlay()
    await greeting.finish()
    try #require(await waitFor { await transport.mediaEnabledHistory == [true] })
    try #require(await waitFor { await events.contains(.greetingCompleted) })
    await transport.emit(.inputAudioSpeechStarted)
    try #require(await waitFor { await events.contains(.userSpeechStarted) })
    await transport.emit(.inputAudioSpeechStopped)
    try #require(await waitFor { await events.contains(.userSpeechEnded) })
    return ClosingFixture(adapter: adapter, transport: transport, greeting: greeting, events: events, collector: collector)
}

private func makeAdapter(
    transports: [GreetingRealtimeTransport],
    greeting: any RecordedGreetingPlayer,
    configuration: OpenAIRealtimeConfiguration
) -> OpenAIRealtimeAdapter {
    OpenAIRealtimeAdapter(
        configuration: configuration,
        clientSecretSource: GreetingSecretSource(),
        transportFactory: GreetingTransportFactory(transports: transports),
        recordedGreeting: greeting
    )
}

private func nextVoiceEvent(
    from stream: AsyncStream<VoiceSessionEvent>
) async -> VoiceSessionEvent? {
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
}

private func waitFor(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< 256 {
        if await condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

private actor ControlledRecordedVoicePlayer: RecordedVoicePlayer {
    private(set) var played: [RecordedVoiceClip] = []
    private var completion: CheckedContinuation<Void, any Error>?

    func play(
        _ clip: RecordedVoiceClip,
        resource _: RecordedVoiceResource
    ) async throws {
        played.append(clip)
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
        }
    }

    func stop() async {
        completion?.resume(throwing: CancellationError())
        completion = nil
    }

    func waitForPlay() async {
        while completion == nil { await Task.yield() }
    }

    func finish() {
        completion?.resume(returning: ())
        completion = nil
    }
}

private actor FailingRecordedVoicePlayer: RecordedVoicePlayer {
    private let error: RecordedVoicePlaybackError

    init(error: RecordedVoicePlaybackError) {
        self.error = error
    }

    func play(
        _: RecordedVoiceClip,
        resource _: RecordedVoiceResource
    ) async throws {
        throw error
    }

    func stop() async {}
}

private actor ControlledGreetingPlayer: RecordedGreetingPlayer {
    private(set) var contexts: [VoiceContext] = []
    private(set) var goodbyeCount = 0
    private(set) var stopCallCount = 0
    private(set) var stopStarted = false
    private var completion: CheckedContinuation<Void, any Error>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopSuspended = false

    func play(context: VoiceContext) async throws {
        contexts.append(context)
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
        }
    }

    func playGoodbye() async throws {
        goodbyeCount += 1
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
        }
    }

    func stop() async {
        stopCallCount += 1
        stopStarted = true
        if stopSuspended {
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
        }
        completion?.resume(throwing: CancellationError())
        completion = nil
    }

    func suspendStop() {
        stopStarted = false
        stopSuspended = true
    }

    func releaseStop() {
        stopSuspended = false
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func waitForPlay() async {
        while completion == nil { await Task.yield() }
    }

    func finish() {
        completion?.resume(returning: ())
        completion = nil
    }

    func waitForGoodbye() async {
        while goodbyeCount == 0 || completion == nil { await Task.yield() }
    }

    func finishGoodbye() {
        completion?.resume(returning: ())
        completion = nil
    }

    func failGoodbye() {
        completion?.resume(throwing: RecordedVoicePlaybackError.playbackFailed)
        completion = nil
    }
}

private actor FailingGreetingPlayer: RecordedGreetingPlayer {
    private(set) var playCallCount = 0

    func play(context _: VoiceContext) async throws {
        playCallCount += 1
        throw RecordedVoicePlaybackError.invalidResource
    }

    func stop() async {}
}

private actor GreetingSecretSource: OpenAIRealtimeClientSecretSource {
    private(set) var receivedConfigurations: [OpenAIRealtimeConfiguration] = []
    func clientSecret(
        for configuration: OpenAIRealtimeConfiguration
    ) async throws -> OpenAIRealtimeClientSecret {
        receivedConfigurations.append(configuration)
        return try OpenAIRealtimeClientSecret(
            value: "test-client-secret",
            expiresAt: Date(timeIntervalSinceNow: 60)
        )
    }
}

private actor GreetingTransportFactory: OpenAIRealtimeTransportFactory {
    private var transports: [GreetingRealtimeTransport]

    init(transports: [GreetingRealtimeTransport]) {
        self.transports = transports
    }

    func makeTransport() async -> any OpenAIRealtimeTransport {
        transports.isEmpty ? GreetingRealtimeTransport() : transports.removeFirst()
    }
}

private actor GreetingRealtimeTransport: OpenAIRealtimeTransport {
    private let stream: AsyncStream<OpenAIRealtimeProviderEvent>
    private let continuation: AsyncStream<OpenAIRealtimeProviderEvent>.Continuation
    private(set) var connectCallCount = 0
    private(set) var connectionPurposes: [OpenAIRealtimeConnectionPurpose] = []
    private(set) var mediaEnabledHistory: [Bool] = []
    private(set) var closeCallCount = 0
    private var mediaDisableFails = false

    func failMediaDisable() { mediaDisableFails = true }

    init() {
        let pair = AsyncStream<OpenAIRealtimeProviderEvent>.makeStream(
            of: OpenAIRealtimeProviderEvent.self,
            bufferingPolicy: .unbounded
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func connect(
        clientSecret _: OpenAIRealtimeClientSecret,
        configuration _: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose,
        enablesWeeklySummaryTool _: Bool
    ) async throws {
        connectCallCount += 1
        connectionPurposes.append(purpose)
    }

    func activate(
        configuration _: OpenAIRealtimeConfiguration,
        enablesWeeklySummaryTool _: Bool,
        enablesVisitorEnrollmentTools _: Bool
    ) async throws {}

    func activate(
        configuration _: OpenAIRealtimeConfiguration,
        enablesWeeklySummaryTool _: Bool,
        enablesVisitorEnrollmentTools _: Bool,
        enablesMemberMemoryTool _: Bool
    ) async throws {}

    func setConversationMediaEnabled(_ enabled: Bool) async throws {
        if !enabled, mediaDisableFails { throw RecordedVoicePlaybackError.playbackFailed }
        mediaEnabledHistory.append(enabled)
    }

    func eventUpdates() async -> AsyncStream<OpenAIRealtimeProviderEvent> {
        stream
    }

    func close() async {
        closeCallCount += 1
        continuation.finish()
    }

    func send(_: Data) async throws {}

    func emit(_ event: OpenAIRealtimeProviderEvent) {
        continuation.yield(event)
    }

    func finishUnexpectedly() {
        continuation.finish()
    }

    func waitForConnect() async {
        while connectCallCount == 0 { await Task.yield() }
    }
}
