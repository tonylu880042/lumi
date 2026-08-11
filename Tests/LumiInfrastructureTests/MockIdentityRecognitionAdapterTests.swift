import LumiApplication
import LumiDomain
import LumiInfrastructure
import Testing

@Suite("Mock identity recognition")
struct MockIdentityRecognitionAdapterTests {
    @Test("publishes a Sendable application port without policy details")
    func portIsSendable() {
        let adapter = MockIdentityRecognitionAdapter()
        let port: any IdentityRecognitionPort = adapter

        acceptsSendable(port)
    }

    @Test("returns an explicitly completed known result exactly")
    func returnsKnownResultAfterExplicitCompletion() async throws {
        let adapter = MockIdentityRecognitionAdapter()
        let expected = RecognitionResult.known(
            memberID: try MemberID(rawValue: "member-001"),
            confidence: try RecognitionConfidence(value: 0.91)
        )
        let request = Task {
            try await adapter.recognizeCurrentVisitor()
        }

        #expect(await waitUntil { await adapter.hasPendingRequest })
        #expect(await adapter.callCount == 1)
        await adapter.complete(with: expected)

        #expect(try await request.value == expected)
        #expect(await adapter.hasPendingRequest == false)
    }

    @Test("returns unknown exactly when unknown is explicitly completed")
    func returnsUnknownResultAfterExplicitCompletion() async throws {
        let adapter = MockIdentityRecognitionAdapter()
        let request = Task {
            try await adapter.recognizeCurrentVisitor()
        }

        #expect(await waitUntil { await adapter.hasPendingRequest })
        await adapter.complete(with: .unknown)

        #expect(try await request.value == .unknown)
    }

    @Test("recognition remains suspended until completion is requested")
    func recognitionSuspendsUntilExplicitCompletion() async throws {
        let adapter = MockIdentityRecognitionAdapter()
        let outcome = RecognitionOutcome()
        let expected = RecognitionResult.unknown
        let request = Task {
            do {
                await outcome.succeed(try await adapter.recognizeCurrentVisitor())
            } catch {
                await outcome.fail(error)
            }
        }

        #expect(await waitUntil { await adapter.hasPendingRequest })
        await Task.yield()
        #expect(await outcome.result == nil)

        await adapter.complete(with: expected)
        await request.value
        #expect(await outcome.result == expected)
        #expect(await outcome.errorDescription == nil)
    }

    @Test("fails a pending recognition with the injected error")
    func failsWithInjectedError() async throws {
        let adapter = MockIdentityRecognitionAdapter()
        let request = Task {
            try await adapter.recognizeCurrentVisitor()
        }

        #expect(await waitUntil { await adapter.hasPendingRequest })
        await adapter.fail(with: TestRecognitionFailure.injected)

        await #expect(throws: TestRecognitionFailure.injected) {
            try await request.value
        }
        #expect(await adapter.hasPendingRequest == false)
    }

    @Test("rejects a second request without replacing the active request")
    func rejectsDuplicateRequest() async throws {
        let adapter = MockIdentityRecognitionAdapter()
        let first = Task {
            try await adapter.recognizeCurrentVisitor()
        }

        #expect(await waitUntil { await adapter.hasPendingRequest })
        await #expect(throws: MockIdentityRecognitionError.operationInProgress) {
            try await adapter.recognizeCurrentVisitor()
        }

        #expect(await adapter.callCount == 2)
        #expect(await adapter.hasPendingRequest)
        await adapter.complete(with: .unknown)
        #expect(try await first.value == .unknown)
    }

    @Test("cancelling a rejected request cannot cancel the active request")
    func rejectedRequestCancellationDoesNotTouchActiveRequest() async throws {
        let adapter = MockIdentityRecognitionAdapter()
        let active = Task {
            try await adapter.recognizeCurrentVisitor()
        }

        #expect(await waitUntil { await adapter.hasPendingRequest })
        let rejected = Task {
            try await adapter.recognizeCurrentVisitor()
        }
        #expect(await waitUntil { await adapter.callCount == 2 })
        rejected.cancel()

        await #expect(throws: MockIdentityRecognitionError.operationInProgress) {
            try await rejected.value
        }
        #expect(await adapter.hasPendingRequest)

        await adapter.complete(with: .unknown)
        #expect(try await active.value == .unknown)
    }

    @Test("cancellation ends with CancellationError and releases pending request")
    func cancellationReleasesPendingRequest() async throws {
        let adapter = MockIdentityRecognitionAdapter()
        let canceled = Task {
            try await adapter.recognizeCurrentVisitor()
        }

        #expect(await waitUntil { await adapter.hasPendingRequest })
        canceled.cancel()

        await #expect(throws: CancellationError.self) {
            try await canceled.value
        }
        #expect(await adapter.hasPendingRequest == false)
    }

    @Test("late completion after cancellation is a no-op and the next request succeeds")
    func lateCompletionCannotResolveNextRequest() async throws {
        let adapter = MockIdentityRecognitionAdapter()
        let canceled = Task {
            try await adapter.recognizeCurrentVisitor()
        }
        let lateResult = RecognitionResult.known(
            memberID: try MemberID(rawValue: "late-result"),
            confidence: try RecognitionConfidence(value: 0.5)
        )
        let nextResult = RecognitionResult.known(
            memberID: try MemberID(rawValue: "next-result"),
            confidence: try RecognitionConfidence(value: 0.8)
        )

        #expect(await waitUntil { await adapter.hasPendingRequest })
        canceled.cancel()
        await #expect(throws: CancellationError.self) {
            try await canceled.value
        }

        await adapter.complete(with: lateResult)
        #expect(await adapter.hasPendingRequest == false)

        let next = Task {
            try await adapter.recognizeCurrentVisitor()
        }
        #expect(await waitUntil { await adapter.hasPendingRequest })
        await adapter.complete(with: nextResult)

        #expect(try await next.value == nextResult)
    }
}

private enum TestRecognitionFailure: Error, Equatable, Sendable {
    case injected
}

private actor RecognitionOutcome {
    private(set) var result: RecognitionResult?
    private(set) var errorDescription: String?

    func succeed(_ result: RecognitionResult) {
        self.result = result
    }

    func fail(_ error: any Error) {
        errorDescription = String(describing: error)
    }
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
