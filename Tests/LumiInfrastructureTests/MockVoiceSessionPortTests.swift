import LumiApplication
import LumiInfrastructure
import Testing

@Suite("Mock voice session")
struct MockVoiceSessionPortTests {
    @Test("voice context is generic, privacy-safe, and Sendable")
    func voiceContextHasNoIdentityPayload() {
        let contexts: [VoiceContext] = [.returningMember, .visitor]

        #expect(contexts == [.returningMember, .visitor])
        #expect(Mirror(reflecting: VoiceContext.returningMember).children.isEmpty)
        #expect(Mirror(reflecting: VoiceContext.visitor).children.isEmpty)

        acceptsSendable(VoiceContext.returningMember)
        acceptsSendable(VoiceContext.visitor)
    }

    @Test("voice event cases are typed semantic values without payloads")
    func voiceEventsHaveNoProviderPayload() {
        let events: [VoiceSessionEvent] = [
            .userSpeechStarted,
            .userSpeechEnded,
            .responseReady,
            .failure,
        ]

        #expect(events == [
            .userSpeechStarted,
            .userSpeechEnded,
            .responseReady,
            .failure,
        ])
        #expect(Mirror(reflecting: VoiceSessionEvent.failure).children.isEmpty)
        acceptsSendable(VoiceSessionEvent.failure)
    }

    @Test("voice port is Sendable and start remains suspended until ready")
    func startWaitsForExplicitReady() async throws {
        let voice = MockVoiceSessionPort()
        let outcome = StartOutcome()
        let request = Task {
            do {
                try await voice.start(context: .returningMember)
                await outcome.succeeded()
            } catch {
                await outcome.failed(error)
            }
        }

        let port: any VoiceSessionPort = voice
        acceptsSendable(port)

        #expect(await waitUntil { await voice.hasPendingStart })
        #expect(await voice.startCallCount == 1)
        #expect(await voice.startContexts == [.returningMember])
        #expect(await voice.startDirections == [.general])
        await Task.yield()
        #expect(await outcome.didSucceed == false)
        #expect(await outcome.errorDescription == nil)
        #expect(await voice.isActive == false)

        await voice.completeStart()
        await request.value
        #expect(await outcome.didSucceed)
        #expect(await outcome.errorDescription == nil)
        #expect(await voice.isActive)
        #expect(await voice.hasPendingStart == false)
    }

    @Test("direction-aware start records focus without an identity payload")
    func directionAwareStartRecordsFocus() async throws {
        let voice = MockVoiceSessionPort()
        let request = Task {
            try await voice.start(
                context: .visitor,
                direction: .postWorkoutReview
            )
        }

        #expect(await waitUntil { await voice.hasPendingStart })
        #expect(await voice.startContexts == [.visitor])
        #expect(await voice.startDirections == [.postWorkoutReview])
        #expect(
            Mirror(reflecting: VoiceConversationDirection.postWorkoutReview)
                .children.isEmpty
        )

        await voice.completeStart()
        try await request.value
    }

    @Test("start failure is injected without provider error details")
    func startFailureIsPropagated() async throws {
        let voice = MockVoiceSessionPort()
        let request = Task {
            try await voice.start(context: .visitor)
        }

        #expect(await waitUntil { await voice.hasPendingStart })
        await voice.failStart(with: TestVoiceFailure.injected)

        await #expect(throws: TestVoiceFailure.injected) {
            try await request.value
        }
        #expect(await voice.hasPendingStart == false)
        #expect(await voice.isActive == false)
    }

    @Test("only one start may be pending and the first continuation remains active")
    func duplicatePendingStartIsRejected() async throws {
        let voice = MockVoiceSessionPort()
        let first = Task {
            try await voice.start(context: .visitor)
        }

        #expect(await waitUntil { await voice.hasPendingStart })
        await #expect(throws: MockVoiceSessionError.startInProgress) {
            try await voice.start(context: .returningMember)
        }

        #expect(await voice.startCallCount == 2)
        #expect(await voice.startContexts == [.visitor, .returningMember])
        #expect(await voice.hasPendingStart)

        await voice.completeStart()
        try await first.value
        #expect(await voice.isActive)
    }

    @Test("starting an already-ready session throws an active-session error")
    func alreadyActiveStartIsRejected() async throws {
        let voice = MockVoiceSessionPort()
        let first = Task {
            try await voice.start(context: .visitor)
        }

        #expect(await waitUntil { await voice.hasPendingStart })
        await voice.completeStart()
        try await first.value

        await #expect(throws: MockVoiceSessionError.alreadyActive) {
            try await voice.start(context: .returningMember)
        }
        #expect(await voice.startCallCount == 2)
        #expect(await voice.startContexts == [.visitor, .returningMember])
        #expect(await voice.isActive)
    }

    @Test("cancelling a pending start releases it and permits retry")
    func cancellationReleasesPendingStart() async throws {
        let voice = MockVoiceSessionPort()
        let canceled = Task {
            try await voice.start(context: .visitor)
        }

        #expect(await waitUntil { await voice.hasPendingStart })
        canceled.cancel()
        await #expect(throws: CancellationError.self) {
            try await canceled.value
        }
        #expect(await voice.hasPendingStart == false)
        #expect(await voice.isActive == false)

        await voice.completeStart()

        let retry = Task {
            try await voice.start(context: .returningMember)
        }
        #expect(await waitUntil { await voice.hasPendingStart })
        await voice.completeStart()
        try await retry.value
        #expect(await voice.isActive)
        #expect(await voice.startContexts == [.visitor, .returningMember])
    }

    @Test("late completion after cancellation cannot resolve the next request")
    func staleCompletionIsIgnoredAfterCancellation() async throws {
        let voice = MockVoiceSessionPort()
        let canceled = Task {
            try await voice.start(context: .visitor)
        }

        #expect(await waitUntil { await voice.hasPendingStart })
        canceled.cancel()
        await #expect(throws: CancellationError.self) {
            try await canceled.value
        }

        await voice.completeStart()
        #expect(await voice.isActive == false)
        #expect(await voice.hasPendingStart == false)

        let next = Task {
            try await voice.start(context: .returningMember)
        }
        #expect(await waitUntil { await voice.hasPendingStart })
        await voice.completeStart()
        try await next.value
        #expect(await voice.isActive)
    }

    @Test("cancellation of a rejected start does not cancel the active request")
    func rejectedCancellationDoesNotTouchActiveStart() async throws {
        let voice = MockVoiceSessionPort()
        let active = Task {
            try await voice.start(context: .visitor)
        }

        #expect(await waitUntil { await voice.hasPendingStart })
        let rejected = Task {
            try await voice.start(context: .returningMember)
        }
        #expect(await waitUntil { await voice.startCallCount == 2 })
        rejected.cancel()

        await #expect(throws: MockVoiceSessionError.startInProgress) {
            try await rejected.value
        }
        #expect(await voice.hasPendingStart)

        await voice.completeStart()
        try await active.value
        #expect(await voice.isActive)
    }

    @Test("event subscribers receive semantic events in emission order")
    func eventsPreserveOrderAndFailureIsSemantic() async throws {
        let voice = MockVoiceSessionPort()
        let start = Task {
            try await voice.start(context: .visitor)
        }
        #expect(await waitUntil { await voice.hasPendingStart })
        await voice.completeStart()
        try await start.value

        let stream = await voice.eventUpdates()
        let observer = Task {
            var received: [VoiceSessionEvent] = []
            for await event in stream {
                received.append(event)
            }
            return received
        }

        let expected: [VoiceSessionEvent] = [
            .userSpeechStarted,
            .userSpeechEnded,
            .responseReady,
            .failure,
        ]
        for event in expected {
            await voice.emit(event)
        }
        await voice.stop()

        #expect(await observer.value == expected)
    }

    @Test("multiple event subscribers each receive the same deterministic sequence")
    func eventsBroadcastToSubscribers() async throws {
        let voice = MockVoiceSessionPort()
        let start = Task {
            try await voice.start(context: .visitor)
        }
        #expect(await waitUntil { await voice.hasPendingStart })
        await voice.completeStart()
        try await start.value

        let first = await voice.eventUpdates()
        let second = await voice.eventUpdates()
        let firstObserver = Task { await collectEvents(from: first) }
        let secondObserver = Task { await collectEvents(from: second) }

        let expected: [VoiceSessionEvent] = [.userSpeechStarted, .responseReady]
        for event in expected {
            await voice.emit(event)
        }
        await voice.stop()

        #expect(await firstObserver.value == expected)
        #expect(await secondObserver.value == expected)
    }

    @Test("events emitted before readiness are ignored")
    func eventsRequireReadySession() async throws {
        let voice = MockVoiceSessionPort()
        let stream = await voice.eventUpdates()
        let observer = Task { await collectEvents(from: stream) }

        await voice.emit(.responseReady)
        await voice.stop()

        #expect(await observer.value.isEmpty)
    }

    @Test("stop is idempotent, cancels pending start, ends streams, and allows restart")
    func stopCancelsAndSupportsRestart() async throws {
        let voice = MockVoiceSessionPort()
        let stream = await voice.eventUpdates()
        let observer = Task { await collectEvents(from: stream) }
        let pending = Task {
            try await voice.start(context: .visitor)
        }

        #expect(await waitUntil { await voice.hasPendingStart })
        await voice.stop()
        await #expect(throws: CancellationError.self) {
            try await pending.value
        }
        #expect(await voice.hasPendingStart == false)
        #expect(await voice.isActive == false)
        #expect(await observer.value.isEmpty)

        await voice.stop()
        #expect(await voice.stopCallCount == 2)
        #expect(await voice.isActive == false)

        let restart = Task {
            try await voice.start(context: .returningMember)
        }
        #expect(await waitUntil { await voice.hasPendingStart })
        await voice.completeStart()
        try await restart.value
        #expect(await voice.isActive)
        #expect(await voice.startContexts == [.visitor, .returningMember])
    }
}

private enum TestVoiceFailure: Error, Equatable, Sendable {
    case injected
}

private actor StartOutcome {
    private(set) var didSucceed = false
    private(set) var errorDescription: String?

    func succeeded() {
        didSucceed = true
    }

    func failed(_ error: any Error) {
        errorDescription = String(describing: error)
    }
}

private func collectEvents(
    from stream: AsyncStream<VoiceSessionEvent>
) async -> [VoiceSessionEvent] {
    var events: [VoiceSessionEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<64 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
