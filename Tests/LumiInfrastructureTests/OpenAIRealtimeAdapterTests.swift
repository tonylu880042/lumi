import Foundation
import LumiApplication
@testable import LumiInfrastructure
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
        #expect(await transport.connectionToolFlags == [false])

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
        let toolUpdates = await adapter.toolCallUpdates()

        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        await transport.emit(.sessionCreated)
        try await start.value

        await adapter.stop()
        await adapter.stop()
        await observer.value
        var toolIterator = toolUpdates.makeAsyncIterator()
        #expect(await toolIterator.next() == nil)

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
        let toolUpdates = await adapter.toolCallUpdates()

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
        var toolIterator = toolUpdates.makeAsyncIterator()
        #expect(await toolIterator.next() == nil)

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
        let toolUpdates = await adapter.toolCallUpdates()

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
        var toolIterator = toolUpdates.makeAsyncIterator()
        #expect(await toolIterator.next() == nil)

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
        let toolUpdates = await adapter.toolCallUpdates()

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
        var toolIterator = toolUpdates.makeAsyncIterator()
        #expect(await toolIterator.next() == nil)

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

    @Test("default tool mode drops provider calls and never sends results")
    func defaultToolModeDropsCallsAndResults() async throws {
        let source = TestClientSecretSource(secrets: [try makeSecret("tool-default-secret")])
        let transport = TestRealtimeTransport()
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [transport])
        )
        let toolUpdates = await adapter.toolCallUpdates()
        let start = Task { try await adapter.start(context: .visitor) }
        let call = VoiceToolCall(callID: "default-call", kind: .getMemberWeeklySummary)
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        await transport.emit(.toolCall(call))
        await transport.emit(.sessionCreated)
        try await start.value
        await transport.emit(.toolCall(call))

        await #expect(throws: OpenAIRealtimeAdapterError.toolTransportUnavailable) {
            try await adapter.sendToolResult(
                VoiceToolResult(
                    callID: call.callID,
                    payload: .failure(.invalidArguments)
                )
            )
        }
        await adapter.stop()
        var iterator = toolUpdates.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(await transport.sentData.isEmpty)
    }

    @Test("enabled initial mode publishes only post-ready tool calls")
    func enabledInitialModePublishesPostReadyCalls() async throws {
        let source = TestClientSecretSource(secrets: [try makeSecret("tool-initial-secret")])
        let transport = TestRealtimeTransport()
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [transport]),
            enablesWeeklySummaryTool: true
        )
        let toolUpdates = await adapter.toolCallUpdates()
        var iterator = toolUpdates.makeAsyncIterator()
        let start = Task { try await adapter.start(context: .visitor) }
        let early = VoiceToolCall(callID: "early-call", kind: .unsupported)
        let ready = VoiceToolCall(callID: "ready-call", kind: .getMemberWeeklySummary)
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        #expect(await transport.connectionToolFlags == [true])
        await transport.emit(.toolCall(early))
        await transport.emit(.sessionCreated)
        try await start.value
        await transport.emit(.toolCall(ready))

        #expect(await iterator.next() == ready)
        await adapter.stop()
        #expect(await iterator.next() == nil)
    }

    @Test("tool subscribers are independent and each receive the normalized call")
    func toolSubscribersAreIndependent() async throws {
        let source = TestClientSecretSource(secrets: [try makeSecret("tool-subscriber-secret")])
        let transport = TestRealtimeTransport()
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [transport]),
            enablesWeeklySummaryTool: true
        )
        var first = (await adapter.toolCallUpdates()).makeAsyncIterator()
        var second = (await adapter.toolCallUpdates()).makeAsyncIterator()
        let start = Task { try await adapter.start(context: .visitor) }
        let call = VoiceToolCall(callID: "subscriber-call", kind: .invalidArguments)
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        await transport.emit(.sessionCreated)
        try await start.value
        await transport.emit(.toolCall(call))

        #expect(await first.next() == call)
        #expect(await second.next() == call)
        await adapter.stop()
        #expect(await first.next() == nil)
        #expect(await second.next() == nil)
    }

    @Test("reconnect preserves tool subscribers but drops calls until fresh readiness")
    func reconnectPreservesToolSubscribersAndReadiness() async throws {
        let source = TestClientSecretSource(secrets: [
            try makeSecret("tool-first-secret"),
            try makeSecret("tool-reconnect-secret"),
        ])
        let firstTransport = TestRealtimeTransport()
        let secondTransport = TestRealtimeTransport()
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [firstTransport, secondTransport]),
            enablesWeeklySummaryTool: true
        )
        var iterator = (await adapter.toolCallUpdates()).makeAsyncIterator()
        let start = Task { try await adapter.start(context: .visitor) }
        let firstCall = VoiceToolCall(callID: "first-call", kind: .getMemberWeeklySummary)
        let staleCall = VoiceToolCall(callID: "stale-call", kind: .unsupported)
        let secondCall = VoiceToolCall(callID: "second-call", kind: .getMemberWeeklySummary)
        let result = VoiceToolResult(
            callID: secondCall.callID,
            payload: .failure(.invalidArguments)
        )
        #expect(await waitUntil { await firstTransport.connectCallCount == 1 })
        await firstTransport.emit(.sessionCreated)
        try await start.value
        await firstTransport.emit(.toolCall(firstCall))
        #expect(await iterator.next() == firstCall)

        await firstTransport.finishUnexpectedly()
        #expect(await waitUntil { await secondTransport.connectCallCount == 1 })
        #expect(await secondTransport.connectionToolFlags == [true])
        await secondTransport.emit(.toolCall(staleCall))
        await #expect(throws: OpenAIRealtimeAdapterError.toolTransportUnavailable) {
            try await adapter.sendToolResult(result)
        }

        await secondTransport.emit(.sessionCreated)
        await secondTransport.emit(.toolCall(secondCall))
        #expect(await iterator.next() == secondCall)
        try await adapter.sendToolResult(result)
        #expect(await secondTransport.sentData == [
            try OpenAIRealtimeWireEncoder.functionCallOutput(for: result),
            try OpenAIRealtimeWireEncoder.responseCreate(),
        ])

        await secondTransport.finishUnexpectedly()
        #expect(await iterator.next() == nil)
    }

    @Test("stale tool result cannot continue after reconnect")
    func staleToolResultCannotContinueAfterReconnect() async throws {
        let source = TestClientSecretSource(secrets: [
            try makeSecret("tool-race-first-secret"),
            try makeSecret("tool-race-reconnect-secret"),
        ])
        let firstTransport = TestRealtimeTransport(blockSendOn: 1)
        let secondTransport = TestRealtimeTransport()
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [firstTransport, secondTransport]),
            enablesWeeklySummaryTool: true
        )
        let result = VoiceToolResult(
            callID: "stale-tool-call",
            payload: .failure(.invalidArguments)
        )
        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await firstTransport.connectCallCount == 1 })
        await firstTransport.emit(.sessionCreated)
        try await start.value

        let sendTask = Task { try await adapter.sendToolResult(result) }
        await firstTransport.waitUntilSendStarted()

        await firstTransport.finishUnexpectedly()
        #expect(await waitUntil { await secondTransport.connectCallCount == 1 })
        await secondTransport.emit(.sessionCreated)
        await firstTransport.releaseSend()

        let error = await thrownAdapterError {
            try await sendTask.value
        }
        #expect(error == .toolResultSendFailed)
        #expect(await firstTransport.sentData == [
            try OpenAIRealtimeWireEncoder.functionCallOutput(for: result),
        ])
        #expect(await secondTransport.sentData.isEmpty)

        await adapter.stop()
    }

    @Test("startup terminal failure finishes tool subscribers")
    func startupTerminalFailureFinishesToolSubscribers() async throws {
        let source = TestClientSecretSource(secrets: [
            try makeSecret("tool-startup-first-secret"),
            try makeSecret("tool-startup-retry-secret"),
        ])
        let firstTransport = TestRealtimeTransport()
        let retryTransport = TestRealtimeTransport()
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [firstTransport, retryTransport]),
            enablesWeeklySummaryTool: true
        )
        let toolUpdates = await adapter.toolCallUpdates()
        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await firstTransport.connectCallCount == 1 })
        await firstTransport.finishUnexpectedly()
        #expect(await waitUntil { await retryTransport.connectCallCount == 1 })
        await retryTransport.finishUnexpectedly()

        await #expect(throws: OpenAIRealtimeAdapterError.connectionEndedBeforeReady) {
            try await start.value
        }
        var iterator = toolUpdates.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test("startup cancellation finishes tool subscribers")
    func startupCancellationFinishesToolSubscribers() async throws {
        let source = TestClientSecretSource(secrets: [try makeSecret("tool-cancel-secret")])
        let transport = TestRealtimeTransport()
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [transport]),
            enablesWeeklySummaryTool: true
        )
        let toolUpdates = await adapter.toolCallUpdates()
        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        start.cancel()

        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        var iterator = toolUpdates.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test("sendToolResult requires readiness and sends exact output then response order")
    func sendToolResultRequiresReadinessAndUsesExactOrder() async throws {
        let source = TestClientSecretSource(secrets: [try makeSecret("tool-send-secret")])
        let transport = TestRealtimeTransport()
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [transport]),
            enablesWeeklySummaryTool: true
        )
        let result = VoiceToolResult(
            callID: "opaque-call-id",
            payload: .failure(.unsupportedTool)
        )
        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        await #expect(throws: OpenAIRealtimeAdapterError.toolTransportUnavailable) {
            try await adapter.sendToolResult(result)
        }
        await transport.emit(.sessionCreated)
        try await start.value

        try await adapter.sendToolResult(result)
        #expect(await transport.sentData == [
            try OpenAIRealtimeWireEncoder.functionCallOutput(for: result),
            try OpenAIRealtimeWireEncoder.responseCreate(),
        ])
        await adapter.stop()
    }

    @Test("first tool result send failure is fixed, redacted, and does not send response")
    func firstToolResultSendFailureIsRedactedAndNonRetrying() async throws {
        let marker = "opaque-call-sensitive-marker"
        let source = TestClientSecretSource(secrets: [try makeSecret("tool-first-failure-secret")])
        let transport = TestRealtimeTransport(
            sendError: TestTransportError.sendFailed,
            failSendOn: 1
        )
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [transport]),
            enablesWeeklySummaryTool: true
        )
        let result = VoiceToolResult(
            callID: marker,
            payload: .failure(.invalidArguments)
        )
        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        await transport.emit(.sessionCreated)
        try await start.value

        let error = await thrownAdapterError {
            try await adapter.sendToolResult(result)
        }
        #expect(error == .toolResultSendFailed)
        assertAdapterErrorRedacted(error, markers: [marker, "sendFailed"])
        #expect(await transport.sendCallCount == 1)
        #expect(await transport.sentData.isEmpty)
        #expect(await transport.closeCallCount == 0)
        await adapter.stop()
    }

    @Test("second tool result send failure does not retry the first output")
    func secondToolResultSendFailureDoesNotRetry() async throws {
        let source = TestClientSecretSource(secrets: [try makeSecret("tool-second-failure-secret")])
        let transport = TestRealtimeTransport(
            sendError: TestTransportError.sendFailed,
            failSendOn: 2
        )
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [transport]),
            enablesWeeklySummaryTool: true
        )
        let result = VoiceToolResult(
            callID: "second-failure-call",
            payload: .failure(.invalidArguments)
        )
        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        await transport.emit(.sessionCreated)
        try await start.value

        await #expect(throws: OpenAIRealtimeAdapterError.toolResultSendFailed) {
            try await adapter.sendToolResult(result)
        }
        #expect(await transport.sendCallCount == 2)
        #expect(await transport.sentData == [
            try OpenAIRealtimeWireEncoder.functionCallOutput(for: result),
        ])
        await adapter.stop()
    }

    @Test("cancellation between tool result sends preserves cancellation and skips response")
    func cancellationBetweenToolResultSendsPreservesCancellation() async throws {
        let source = TestClientSecretSource(secrets: [try makeSecret("tool-between-cancel-secret")])
        let transport = TestRealtimeTransport(blockSendOn: 1)
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [transport]),
            enablesWeeklySummaryTool: true
        )
        let result = VoiceToolResult(
            callID: "between-cancel-call",
            payload: .failure(.invalidArguments)
        )
        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        await transport.emit(.sessionCreated)
        try await start.value

        let sendTask = Task { try await adapter.sendToolResult(result) }
        await transport.waitUntilSendStarted()
        sendTask.cancel()
        await transport.releaseSend()
        await #expect(throws: CancellationError.self) {
            try await sendTask.value
        }
        #expect(await transport.sendCallCount == 1)
        await adapter.stop()
    }

    @Test("successful second tool result send wins after cancellation")
    func successfulSecondToolResultSendWinsAfterCancellation() async throws {
        let source = TestClientSecretSource(secrets: [try makeSecret("tool-after-cancel-secret")])
        let transport = TestRealtimeTransport(blockSendOn: 2)
        let adapter = makeAdapter(
            source: source,
            factory: TestRealtimeTransportFactory(transports: [transport]),
            enablesWeeklySummaryTool: true
        )
        let result = VoiceToolResult(
            callID: "after-cancel-call",
            payload: .failure(.unsupportedTool)
        )
        let start = Task { try await adapter.start(context: .visitor) }
        #expect(await waitUntil { await transport.connectCallCount == 1 })
        await transport.emit(.sessionCreated)
        try await start.value

        let sendTask = Task { try await adapter.sendToolResult(result) }
        await transport.waitUntilSendStarted()
        #expect(await transport.sendCallCount == 2)
        sendTask.cancel()
        await transport.releaseSend()
        try await sendTask.value
        #expect(await transport.sentData == [
            try OpenAIRealtimeWireEncoder.functionCallOutput(for: result),
            try OpenAIRealtimeWireEncoder.responseCreate(),
        ])
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
    private let sendError: (any Error)?
    private let failSendOn: Int?
    private let blockSendOn: Int?
    private(set) var connectCallCount = 0
    private(set) var connectionPurposes: [OpenAIRealtimeConnectionPurpose] = []
    private(set) var connectionToolFlags: [Bool] = []
    private(set) var closeCallCount = 0
    private(set) var sendCallCount = 0
    private(set) var sendStarted = false
    private(set) var sentData: [Data] = []
    private var continuation: AsyncStream<OpenAIRealtimeProviderEvent>.Continuation?
    private var pendingSend: CheckedContinuation<Void, Never>?
    private var sendStartedWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        connectError: (any Error)? = nil,
        sendError: (any Error)? = nil,
        failSendOn: Int? = nil,
        blockSendOn: Int? = nil
    ) {
        self.connectError = connectError
        self.sendError = sendError
        self.failSendOn = failSendOn ?? (sendError == nil ? nil : 1)
        self.blockSendOn = blockSendOn
    }

    func connect(
        clientSecret _: OpenAIRealtimeClientSecret,
        configuration _: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose,
        enablesWeeklySummaryTool: Bool
    ) async throws {
        connectCallCount += 1
        connectionPurposes.append(purpose)
        connectionToolFlags.append(enablesWeeklySummaryTool)
        if let connectError { throw connectError }
    }

    func send(_ data: Data) async throws {
        sendCallCount += 1
        if blockSendOn == sendCallCount {
            sendStarted = true
            let waiters = sendStartedWaiters
            sendStartedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                pendingSend = continuation
            }
        }
        if let sendError, failSendOn == sendCallCount { throw sendError }
        sentData.append(data)
    }

    func releaseSend() {
        pendingSend?.resume()
        pendingSend = nil
    }

    func waitUntilSendStarted() async {
        if sendStarted { return }
        await withCheckedContinuation { continuation in
            sendStartedWaiters.append(continuation)
        }
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
        purpose _: OpenAIRealtimeConnectionPurpose,
        enablesWeeklySummaryTool _: Bool
    ) async throws {
        throw TestTransportError.exhaustedTransports
    }

    func send(_: Data) async throws {}

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
    case sendFailed
}

private func makeAdapter(
    source: TestClientSecretSource,
    factory: TestRealtimeTransportFactory,
    enablesWeeklySummaryTool: Bool = false
) -> OpenAIRealtimeAdapter {
    OpenAIRealtimeAdapter(
        configuration: OpenAIRealtimeConfiguration(),
        clientSecretSource: source,
        transportFactory: factory,
        enablesWeeklySummaryTool: enablesWeeklySummaryTool
    )
}

private func thrownAdapterError(
    _ operation: () async throws -> Void
) async -> OpenAIRealtimeAdapterError {
    do {
        try await operation()
        Issue.record("Expected adapter operation to throw")
        return .toolResultSendFailed
    } catch let error as OpenAIRealtimeAdapterError {
        return error
    } catch {
        Issue.record("Unexpected adapter error: \(error)")
        return .toolResultSendFailed
    }
}

private func assertAdapterErrorRedacted(
    _ error: OpenAIRealtimeAdapterError,
    markers: [String]
) {
    for diagnostic in [String(describing: error), String(reflecting: error)] {
        for marker in markers {
            #expect(!diagnostic.contains(marker))
        }
    }
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
