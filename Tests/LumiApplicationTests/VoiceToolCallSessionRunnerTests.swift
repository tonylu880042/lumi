import Foundation
import LumiApplication
import LumiDomain
import Testing

@Suite("Voice tool-call session runner")
struct VoiceToolCallSessionRunnerTests {
    @Test("prepare registers the tool stream before returning")
    func prepareRegistersToolStreamBeforeReturning() async throws {
        let port = TestVoiceToolCallPort()
        let repository = RecordingMemberRepository(summary: makeSummary(visits: 1))

        _ = await VoiceToolCallSessionRunner.prepare(
            port: port,
            memberID: try MemberID(rawValue: "M-prepare"),
            weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                repository: repository
            )
        )

        #expect(await port.toolCallUpdatesCallCount == 1)
    }

    @Test("serializes calls and sends results in stream order")
    func serializesCallsAndSendsResultsInOrder() async throws {
        let memberID = try MemberID(rawValue: "M-serial")
        let firstCall = VoiceToolCall(callID: "first", kind: .getMemberWeeklySummary)
        let secondCall = VoiceToolCall(callID: "second", kind: .getMemberWeeklySummary)
        let port = TestVoiceToolCallPort(blockSendOn: 1)
        let repository = RecordingMemberRepository(summary: makeSummary(visits: 2))
        let runner = await makeRunner(
            port: port,
            memberID: memberID,
            repository: repository
        )
        let runTask = Task { try await runner.run() }

        await port.emit(firstCall)
        await port.waitUntilSendStarted()
        #expect(await repository.weeklySummaryRequests == [memberID])

        await port.emit(secondCall)
        #expect(await repository.weeklySummaryRequests == [memberID])

        await port.releaseSend()
        await port.waitUntilSentCount(2)
        #expect(await repository.weeklySummaryRequests == [memberID, memberID])
        #expect(await port.sentResults.map(\.callID) == [firstCall.callID, secondCall.callID])

        await port.finish()
        try await runTask.value
    }

    @Test("routes every lookup to the exact locally bound member ID")
    func routesExactLocalMemberID() async throws {
        let memberID = try MemberID(rawValue: "  M-exact / local  ")
        let port = TestVoiceToolCallPort()
        let repository = RecordingMemberRepository(summary: makeSummary(visits: 3))
        let runner = await makeRunner(
            port: port,
            memberID: memberID,
            repository: repository
        )
        let runTask = Task { try await runner.run() }

        await port.emit(
            VoiceToolCall(callID: "exact-member", kind: .getMemberWeeklySummary)
        )
        await port.waitUntilSentCount(1)
        await port.finish()
        try await runTask.value

        #expect(await repository.weeklySummaryRequests == [memberID])
    }

    @Test("maps repository failure to the fixed member-data-unavailable result")
    func mapsRepositoryFailure() async throws {
        let port = TestVoiceToolCallPort()
        let repository = RecordingMemberRepository(error: .generic)
        let runner = await makeRunner(
            port: port,
            memberID: try MemberID(rawValue: "M-repository-error"),
            repository: repository
        )
        let runTask = Task { try await runner.run() }

        await port.emit(
            VoiceToolCall(callID: "repository-error", kind: .getMemberWeeklySummary)
        )
        await port.waitUntilSentCount(1)
        #expect(
            await port.sentResults.first?.payload == .failure(.memberDataUnavailable)
        )

        await port.finish()
        try await runTask.value
    }

    @Test("preserves the original send error")
    func preservesOriginalSendError() async throws {
        let port = TestVoiceToolCallPort(sendError: .transportFailure)
        let repository = RecordingMemberRepository(summary: makeSummary(visits: 1))
        let runner = await makeRunner(
            port: port,
            memberID: try MemberID(rawValue: "M-send-error"),
            repository: repository
        )
        await port.emit(
            VoiceToolCall(callID: "send-error", kind: .getMemberWeeklySummary)
        )

        await #expect(throws: TestVoiceToolCallPortError.transportFailure) {
            try await runner.run()
        }
        #expect(await port.sentResults.isEmpty)
        await port.finish()
    }

    @Test("pre-cancellation does not query or send a later call")
    func preCancellationStopsBeforeFirstCall() async throws {
        let port = TestVoiceToolCallPort()
        let repository = RecordingMemberRepository(summary: makeSummary(visits: 1))
        let runner = await makeRunner(
            port: port,
            memberID: try MemberID(rawValue: "M-pre-cancel"),
            repository: repository
        )
        await port.emit(
            VoiceToolCall(callID: "pre-cancel", kind: .getMemberWeeklySummary)
        )

        let runTask = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try await runner.run()
        }

        await #expect(throws: CancellationError.self) {
            try await runTask.value
        }
        #expect(await repository.weeklySummaryRequests.isEmpty)
        #expect(await port.sentResults.isEmpty)
        await port.finish()
    }

    @Test("repository cancellation preserves cancellation and stops later calls")
    func repositoryCancellationStopsLaterCalls() async throws {
        let port = TestVoiceToolCallPort()
        let repository = GatedMemberRepository()
        let runner = await makeRunner(
            port: port,
            memberID: try MemberID(rawValue: "M-repository-cancel"),
            repository: repository
        )
        let runTask = Task { try await runner.run() }
        await port.emit(
            VoiceToolCall(callID: "repository-cancel", kind: .getMemberWeeklySummary)
        )
        await repository.waitUntilRequested()

        runTask.cancel()
        await repository.succeed(with: makeSummary(visits: 4))

        await #expect(throws: CancellationError.self) {
            try await runTask.value
        }
        await port.emit(
            VoiceToolCall(callID: "after-repository-cancel", kind: .getMemberWeeklySummary)
        )
        #expect(await repository.weeklySummaryRequests == [try MemberID(rawValue: "M-repository-cancel")])
        #expect(await port.sentResults.isEmpty)
        await port.finish()
    }

    @Test("send cancellation preserves cancellation and stops later calls")
    func sendCancellationStopsLaterCalls() async throws {
        let port = TestVoiceToolCallPort(blockSendOn: 1)
        let repository = RecordingMemberRepository(summary: makeSummary(visits: 5))
        let runner = await makeRunner(
            port: port,
            memberID: try MemberID(rawValue: "M-send-cancel"),
            repository: repository
        )
        let runTask = Task { try await runner.run() }
        await port.emit(
            VoiceToolCall(callID: "send-cancel", kind: .getMemberWeeklySummary)
        )
        await port.waitUntilSendStarted()

        runTask.cancel()
        await port.releaseSend()

        await #expect(throws: CancellationError.self) {
            try await runTask.value
        }
        await port.emit(
            VoiceToolCall(callID: "after-send-cancel", kind: .getMemberWeeklySummary)
        )
        #expect(await repository.weeklySummaryRequests.count == 1)
        #expect(await port.sentResults.isEmpty)
        await port.finish()
    }

    @Test("cancellation while waiting for the next call preserves cancellation")
    func cancellationWhileWaitingForNextCallPreservesCancellation() async throws {
        let port = TestVoiceToolCallPort()
        let repository = RecordingMemberRepository(summary: makeSummary(visits: 6))
        let memberID = try MemberID(rawValue: "M-wait-cancel")
        let runner = await makeRunner(
            port: port,
            memberID: memberID,
            repository: repository
        )
        let runTask = Task { try await runner.run() }

        await port.emit(
            VoiceToolCall(callID: "before-wait-cancel", kind: .getMemberWeeklySummary)
        )
        await port.waitUntilSentCount(1)

        runTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await runTask.value
        }
        #expect(await repository.weeklySummaryRequests == [memberID])
        #expect(await port.sentResults.count == 1)
        await port.finish()
    }

    @Test("normal stream termination returns successfully")
    func normalStreamTerminationReturns() async throws {
        let port = TestVoiceToolCallPort()
        let runner = await makeRunner(
            port: port,
            memberID: try MemberID(rawValue: "M-finish"),
            repository: RecordingMemberRepository(summary: makeSummary(visits: 1))
        )
        let runTask = Task { try await runner.run() }

        await port.finish()
        try await runTask.value
    }
}

private func makeRunner(
    port: TestVoiceToolCallPort,
    memberID: MemberID,
    repository: any MemberRepository
) async -> VoiceToolCallSessionRunner {
    await VoiceToolCallSessionRunner.prepare(
        port: port,
        memberID: memberID,
        weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
            repository: repository
        )
    )
}

private func makeSummary(visits: Int) -> ExerciseSummary {
    ExerciseSummary(
        visitsThisWeek: visits,
        activityMETMinutes: 120,
        lastWorkoutAt: nil,
        todayCompleted: true
    )
}

private actor TestVoiceToolCallPort: VoiceToolCallPort {
    private let stream: AsyncStream<VoiceToolCall>
    private let continuation: AsyncStream<VoiceToolCall>.Continuation
    private let sendError: TestVoiceToolCallPortError?
    private let blockSendOn: Int?
    private var pendingSend: CheckedContinuation<Void, Never>?
    private var sendStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var sentCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    private(set) var toolCallUpdatesCallCount = 0
    private(set) var sendCallCount = 0
    private(set) var sendStarted = false
    private(set) var sentResults: [VoiceToolResult] = []

    init(
        sendError: TestVoiceToolCallPortError? = nil,
        blockSendOn: Int? = nil
    ) {
        let pair = AsyncStream<VoiceToolCall>.makeStream(
            of: VoiceToolCall.self,
            bufferingPolicy: .unbounded
        )
        stream = pair.stream
        continuation = pair.continuation
        self.sendError = sendError
        self.blockSendOn = blockSendOn
    }

    func toolCallUpdates() async -> AsyncStream<VoiceToolCall> {
        toolCallUpdatesCallCount += 1
        return stream
    }

    func sendToolResult(_ result: VoiceToolResult) async throws {
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

        try Task.checkCancellation()
        if let sendError {
            throw sendError
        }
        sentResults.append(result)
        let readyWaiters = sentCountWaiters
            .filter { $0.key <= sentResults.count }
            .flatMap(\.value)
        sentCountWaiters = sentCountWaiters.filter { $0.key > sentResults.count }
        for waiter in readyWaiters {
            waiter.resume()
        }
    }

    func emit(_ call: VoiceToolCall) {
        continuation.yield(call)
    }

    func finish() {
        continuation.finish()
    }

    func waitUntilSendStarted() async {
        if sendStarted { return }
        await withCheckedContinuation { continuation in
            sendStartedWaiters.append(continuation)
        }
    }

    func waitUntilSentCount(_ count: Int) async {
        if sentResults.count >= count { return }
        await withCheckedContinuation { continuation in
            sentCountWaiters[count, default: []].append(continuation)
        }
    }

    func releaseSend() {
        pendingSend?.resume()
        pendingSend = nil
    }

    deinit {
        continuation.finish()
    }
}

private enum TestVoiceToolCallPortError: Error, Equatable, Sendable {
    case transportFailure
}

private actor RecordingMemberRepository: MemberRepository {
    private let outcome: Outcome
    private(set) var weeklySummaryRequests: [MemberID] = []

    init(summary: ExerciseSummary) {
        outcome = .success(summary)
    }

    init(error: RepositoryTestError) {
        outcome = .failure(error)
    }

    func profile(for id: MemberID) async throws -> Member {
        throw RepositoryTestError.profileUnsupported
    }

    func weeklySummary(for id: MemberID) async throws -> ExerciseSummary {
        weeklySummaryRequests.append(id)
        switch outcome {
        case let .success(summary):
            return summary
        case let .failure(error):
            throw error
        }
    }

    private enum Outcome: Sendable {
        case success(ExerciseSummary)
        case failure(RepositoryTestError)
    }
}

private actor GatedMemberRepository: MemberRepository {
    private var pending: CheckedContinuation<ExerciseSummary, any Error>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var weeklySummaryRequests: [MemberID] = []

    func profile(for id: MemberID) async throws -> Member {
        throw RepositoryTestError.profileUnsupported
    }

    func weeklySummary(for id: MemberID) async throws -> ExerciseSummary {
        weeklySummaryRequests.append(id)
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
        }
    }

    func waitUntilRequested() async {
        guard weeklySummaryRequests.isEmpty else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func succeed(with summary: ExerciseSummary) {
        pending?.resume(returning: summary)
        pending = nil
    }
}

private enum RepositoryTestError: Error, Sendable {
    case generic
    case profileUnsupported
}
