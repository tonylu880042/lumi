import Foundation
import LumiApplication
import LumiInfrastructure
import Testing

@Suite("OpenAI Realtime adapter")
struct OpenAIRealtimeAdapterTests {
    @Test("start waits for readiness and broadcasts mapped voice events")
    func startWaitsForReadinessAndBroadcastsEvents() async throws {
        let source = TestClientSecretSource(secrets: [try makeSecret("ready-secret")])
        let transport = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory(transports: [transport])
        let adapter = makeAdapter(source: source, factory: factory)
        let recorder = EventRecorder()
        let observer = await observe(adapter: adapter, recorder: recorder)
        let completion = CompletionProbe()

        let start = Task {
            try await adapter.start(context: .visitor)
            await completion.markCompleted()
        }
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        #expect(await completion.isCompleted == false)

        await transport.emit(.sessionCreated)
        try await start.value
        #expect(await completion.isCompleted)
        #expect(await transport.connectionPurposes == [.initial])

        await transport.emit(.outputAudioStarted)
        await transport.emit(.inputAudioSpeechStarted)
        await transport.emit(.outputAudioCleared)
        await transport.emit(.inputAudioSpeechStarted)
        await transport.emit(.inputAudioSpeechStopped)
        await transport.emit(.outputAudioStarted)

        #expect(await waitUntil { await recorder.count == 4 })
        #expect(await recorder.events == [
            .assistantInterrupted,
            .userSpeechStarted,
            .userSpeechEnded,
            .responseReady,
        ])

        await adapter.stop()
        await observer.value
    }

    @Test("stop is idempotent and finishes subscribers without a failure")
    func stopIsIdempotentAndClean() async throws {
        let source = TestClientSecretSource(secrets: [try makeSecret("stop-secret")])
        let transport = TestRealtimeTransport()
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [transport])
        )
        let recorder = EventRecorder()
        let observer = await observe(adapter: adapter, recorder: recorder)

        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        await transport.emit(.sessionCreated)
        try await start.value

        await adapter.stop()
        await adapter.stop()
        await observer.value

        #expect(await transport.closeCallCount == 1)
        #expect(await recorder.events.isEmpty)
        #expect(await source.callCount == 1)
    }

    @Test("pending and active duplicate starts use typed errors")
    func duplicateStartsAreTyped() async throws {
        let source = TestClientSecretSource(secrets: [try makeSecret("duplicate-secret")])
        let transport = TestRealtimeTransport()
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [transport])
        )

        let first = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        await #expect(throws: OpenAIRealtimeAdapterError.startInProgress) {
            try await adapter.start(context: .returningMember)
        }

        await transport.emit(.sessionCreated)
        try await first.value
        await #expect(throws: OpenAIRealtimeAdapterError.alreadyActive) {
            try await adapter.start(context: .visitor)
        }

        await adapter.stop()
    }

    @Test("voice context adds only a privacy-safe greeting instruction")
    func voiceContextIsAppliedWithoutMemberDetails() async throws {
        let source = TestClientSecretSource(secrets: [try makeSecret("context-secret")])
        let transport = TestRealtimeTransport()
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [transport])
        )

        let start = Task { try await adapter.start(context: .returningMember) }
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        await transport.emit(.sessionCreated)
        try await start.value

        let configurations = await source.receivedConfigurations
        #expect(configurations.count == 1)
        #expect(configurations[0].model == "gpt-realtime-2.1-mini")
        #expect(configurations[0].voice == "marin")
        #expect(configurations[0].instructions.contains("歡迎回來"))
        #expect(configurations[0].instructions.contains("不要說出姓名"))

        await adapter.stop()
    }

    @Test("unexpected disconnect reconnects once with a fresh credential")
    func unexpectedDisconnectReconnectsOnce() async throws {
        let source = TestClientSecretSource(secrets: [
            try makeSecret("first-secret"),
            try makeSecret("second-secret"),
            try makeSecret("third-secret"),
        ])
        let firstTransport = TestRealtimeTransport()
        let secondTransport = TestRealtimeTransport()
        let thirdTransport = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory(
            transports: [firstTransport, secondTransport, thirdTransport]
        )
        let adapter = makeAdapter(source: source, factory: factory)
        let recorder = EventRecorder()
        let observer = await observe(adapter: adapter, recorder: recorder)

        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await firstTransport.connectCallCount == 1 })
        await firstTransport.emit(.sessionCreated)
        try await start.value

        await firstTransport.finishUnexpectedly()
        #expect(await waitUntil { await secondTransport.connectCallCount == 1 })
        #expect(await source.callCount == 2)
        #expect(await factory.makeCallCount == 2)
        #expect(await firstTransport.connectionPurposes == [.initial])
        #expect(await secondTransport.connectionPurposes == [.reconnect])

        await secondTransport.emit(.inputAudioSpeechStarted)
        for _ in 0 ..< 8 { await Task.yield() }
        #expect(await recorder.events.isEmpty)

        await secondTransport.emit(.sessionCreated)
        await secondTransport.emit(.inputAudioSpeechStarted)
        #expect(await waitUntil { await recorder.count == 1 })
        #expect(await recorder.events == [.userSpeechStarted])

        await firstTransport.emit(.error)
        for _ in 0 ..< 8 { await Task.yield() }
        #expect(await recorder.events == [.userSpeechStarted])
        #expect(await firstTransport.closeCallCount == 1)

        await secondTransport.finishUnexpectedly()
        #expect(await waitUntil { await recorder.count == 2 })
        #expect(await recorder.events == [.userSpeechStarted, .failure])
        #expect(await source.callCount == 2)
        #expect(await factory.makeCallCount == 2)

        await observer.value

        let freshRecorder = EventRecorder()
        let freshObserver = await observe(adapter: adapter, recorder: freshRecorder)
        let freshStart = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await thirdTransport.connectCallCount == 1 })
        await thirdTransport.emit(.sessionCreated)
        try await freshStart.value
        #expect(await source.callCount == 3)
        #expect(await factory.makeCallCount == 3)

        await adapter.stop()
        await freshObserver.value
        #expect(await secondTransport.closeCallCount == 1)
    }

    @Test("failed reconnect emits one failure without a third attempt")
    func failedReconnectEmitsOneFailure() async throws {
        let source = TestClientSecretSource(secrets: [
            try makeSecret("first-secret"),
            try makeSecret("retry-secret"),
            try makeSecret("third-secret"),
        ])
        let firstTransport = TestRealtimeTransport()
        let retryTransport = TestRealtimeTransport(connectError: TestTransportError.connectFailed)
        let thirdTransport = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory(
            transports: [firstTransport, retryTransport, thirdTransport]
        )
        let adapter = makeAdapter(source: source, factory: factory)
        let recorder = EventRecorder()
        let observer = await observe(adapter: adapter, recorder: recorder)

        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await firstTransport.connectCallCount == 1 })
        await firstTransport.emit(.sessionCreated)
        try await start.value

        await firstTransport.finishUnexpectedly()
        #expect(await waitUntil { await recorder.count == 1 })
        #expect(await recorder.events == [.failure])
        for _ in 0 ..< 8 { await Task.yield() }
        #expect(await source.callCount == 2)
        #expect(await factory.makeCallCount == 2)
        #expect(await recorder.events == [.failure])
        await observer.value

        let freshRecorder = EventRecorder()
        let freshObserver = await observe(adapter: adapter, recorder: freshRecorder)
        let freshStart = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await thirdTransport.connectCallCount == 1 })
        await thirdTransport.emit(.sessionCreated)
        try await freshStart.value
        #expect(await source.callCount == 3)
        #expect(await factory.makeCallCount == 3)

        await adapter.stop()
        await freshObserver.value
        #expect(await retryTransport.closeCallCount == 1)
    }

    @Test("active reconnect authorization invalidation does not emit generic failure")
    func activeReconnectAuthorizationInvalidationDoesNotEmitGenericFailure() async throws {
        let source = TestClientSecretSource(outcomes: [
            .secret(try makeSecret("first-secret")),
            .authorizationRequired,
            .secret(try makeSecret("third-secret")),
        ])
        let firstTransport = TestRealtimeTransport()
        let secondTransport = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory(
            transports: [firstTransport, secondTransport]
        )
        let adapter = makeAdapter(
            source: source,
            factory: factory
        )
        let recorder = EventRecorder()
        let observer = await observe(adapter: adapter, recorder: recorder)

        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await firstTransport.connectCallCount == 1 })
        await firstTransport.emit(.sessionCreated)
        try await start.value

        await firstTransport.finishUnexpectedly()
        #expect(await waitUntil { await source.callCount == 2 })
        #expect(await waitUntil { await recorder.count == 1 })
        #expect(await recorder.events == [.authorizationRequired])
        #expect(await factory.makeCallCount == 1)
        await observer.value

        let freshObserver = await observe(adapter: adapter, recorder: EventRecorder())
        let freshStart = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await secondTransport.connectCallCount == 1 })
        await secondTransport.emit(.sessionCreated)
        try await freshStart.value
        #expect(await source.callCount == 3)
        #expect(await factory.makeCallCount == 2)

        await adapter.stop()
        await freshObserver.value
    }

    @Test("two disconnects before readiness fail startup without a third attempt")
    func startupDisconnectRetryIsBounded() async throws {
        let source = TestClientSecretSource(secrets: [
            try makeSecret("first-secret"),
            try makeSecret("retry-secret"),
        ])
        let firstTransport = TestRealtimeTransport()
        let retryTransport = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory(
            transports: [firstTransport, retryTransport]
        )
        let adapter = makeAdapter(source: source, factory: factory)

        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await firstTransport.connectCallCount == 1 })
        await firstTransport.finishUnexpectedly()
        #expect(await waitUntil { await retryTransport.connectCallCount == 1 })
        await retryTransport.finishUnexpectedly()

        await #expect(throws: OpenAIRealtimeAdapterError.connectionEndedBeforeReady) {
            try await start.value
        }
        #expect(await source.callCount == 2)
        #expect(await factory.makeCallCount == 2)

        await adapter.stop()
    }

    @Test("cancelling startup closes it and permits a fresh retry")
    func startupCancellationIsRetryable() async throws {
        let source = TestClientSecretSource(secrets: [
            try makeSecret("cancelled-secret"),
            try makeSecret("retry-secret"),
        ])
        let cancelledTransport = TestRealtimeTransport()
        let retryTransport = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory(
            transports: [cancelledTransport, retryTransport]
        )
        let adapter = makeAdapter(source: source, factory: factory)

        let cancelledStart = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await cancelledTransport.connectCallCount == 1 })
        cancelledStart.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledStart.value
        }
        #expect(await waitUntil { await cancelledTransport.closeCallCount == 1 })

        let retry = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await retryTransport.connectCallCount == 1 })
        await retryTransport.emit(.sessionCreated)
        try await retry.value
        #expect(await source.callCount == 2)

        await adapter.stop()
    }
}

private actor TestClientSecretSource: OpenAIRealtimeClientSecretSource {
    private var outcomes: [TestClientSecretOutcome]
    private(set) var callCount = 0
    private(set) var receivedConfigurations: [OpenAIRealtimeConfiguration] = []

    init(secrets: [OpenAIRealtimeClientSecret]) {
        self.outcomes = secrets.map(TestClientSecretOutcome.secret)
    }

    init(outcomes: [TestClientSecretOutcome]) {
        self.outcomes = outcomes
    }

    func clientSecret(
        for configuration: OpenAIRealtimeConfiguration
    ) async throws -> OpenAIRealtimeClientSecret {
        callCount += 1
        receivedConfigurations.append(configuration)
        guard !outcomes.isEmpty else { throw TestTransportError.exhaustedCredentials }
        switch outcomes.removeFirst() {
        case .secret(let secret):
            return secret
        case .authorizationRequired:
            throw VoiceSessionAuthorizationError.authorizationRequired
        }
    }
}

private enum TestClientSecretOutcome: Sendable {
    case secret(OpenAIRealtimeClientSecret)
    case authorizationRequired
}

private actor TestRealtimeTransportFactory: OpenAIRealtimeTransportFactory {
    private var transports: [any OpenAIRealtimeTransport]
    private(set) var makeCallCount = 0

    init(transports: [any OpenAIRealtimeTransport]) {
        self.transports = transports
    }

    func makeTransport() async -> any OpenAIRealtimeTransport {
        makeCallCount += 1
        guard !transports.isEmpty else { return ExhaustedRealtimeTransport() }
        return transports.removeFirst()
    }
}

private actor TestRealtimeTransport: OpenAIRealtimeTransport {
    private let connectError: (any Error)?
    private(set) var connectCallCount = 0
    private(set) var connectionPurposes: [OpenAIRealtimeConnectionPurpose] = []
    private(set) var closeCallCount = 0
    private var continuation: AsyncStream<OpenAIRealtimeProviderEvent>.Continuation?

    init(connectError: (any Error)? = nil) {
        self.connectError = connectError
    }

    func connect(
        clientSecret _: OpenAIRealtimeClientSecret,
        configuration _: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose
    ) async throws {
        connectCallCount += 1
        connectionPurposes.append(purpose)
        if let connectError { throw connectError }
    }

    func eventUpdates() -> AsyncStream<OpenAIRealtimeProviderEvent> {
        let pair = AsyncStream<OpenAIRealtimeProviderEvent>.makeStream(
            of: OpenAIRealtimeProviderEvent.self,
            bufferingPolicy: .unbounded
        )
        continuation = pair.continuation
        return pair.stream
    }

    func close() {
        closeCallCount += 1
        continuation?.finish()
    }

    func emit(_ event: OpenAIRealtimeProviderEvent) {
        continuation?.yield(event)
    }

    func finishUnexpectedly() {
        continuation?.finish()
    }
}

private actor ExhaustedRealtimeTransport: OpenAIRealtimeTransport {
    func connect(
        clientSecret _: OpenAIRealtimeClientSecret,
        configuration _: OpenAIRealtimeConfiguration,
        purpose _: OpenAIRealtimeConnectionPurpose
    ) async throws {
        throw TestTransportError.exhaustedTransports
    }

    func eventUpdates() -> AsyncStream<OpenAIRealtimeProviderEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func close() {}
}

private actor EventRecorder {
    private(set) var events: [VoiceSessionEvent] = []

    var count: Int { events.count }

    func append(_ event: VoiceSessionEvent) {
        events.append(event)
    }
}

private actor CompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

private enum TestTransportError: Error, Equatable, Sendable {
    case connectFailed
    case exhaustedCredentials
    case exhaustedTransports
}

private func makeAdapter(
    source: TestClientSecretSource,
    factory: TestRealtimeTransportFactory
) -> OpenAIRealtimeAdapter {
    OpenAIRealtimeAdapter(
        configuration: OpenAIRealtimeConfiguration(),
        clientSecretSource: source,
        transportFactory: factory
    )
}

private func makeSecret(_ value: String) throws -> OpenAIRealtimeClientSecret {
    try OpenAIRealtimeClientSecret(
        value: value,
        expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
}

private func observe(
    adapter: OpenAIRealtimeAdapter,
    recorder: EventRecorder
) async -> Task<Void, Never> {
    let stream = await adapter.eventUpdates()
    return Task {
        for await event in stream {
            await recorder.append(event)
        }
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< 256 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
