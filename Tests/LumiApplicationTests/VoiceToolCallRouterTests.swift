import Foundation
import LumiApplication
import LumiDomain
import Testing

@Suite("Voice tool-call router")
struct VoiceToolCallRouterTests {
    @Test("routes a known weekly-summary call with an exact member ID")
    func routesKnownWeeklySummaryCall() async throws {
        let memberID = try MemberID(rawValue: "  M-001/exact  ")
        let repository = RecordingMemberRepository(
            summary: ExerciseSummary(
                visitsThisWeek: 2,
                activityMETMinutes: 580.5,
                lastWorkoutAt: Date(timeIntervalSince1970: 1_785_983_400),
                todayCompleted: false
            )
        )
        let router = VoiceToolCallRouter(
            weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                repository: repository
            )
        )
        let call = VoiceToolCall(
            callID: "weekly-summary-call",
            kind: .getMemberWeeklySummary(memberID: memberID)
        )

        let result = try await router.result(for: call)

        #expect(result.callID == call.callID)
        #expect(
            String(data: result.jsonData(), encoding: .utf8)
                == #"{"activity_met_minutes":580.5,"last_workout_at":"2026-08-06T02:30:00.000Z","today_completed":false,"visits_this_week":2}"#
        )
        #expect(await repository.weeklySummaryRequests == [memberID])
        acceptsSendable(router)
        acceptsSendable(result)
    }

    @Test("maps unsupported and invalid argument calls to fixed failures")
    func mapsUnsupportedAndInvalidArguments() async throws {
        let repository = RecordingMemberRepository(
            summary: ExerciseSummary(
                visitsThisWeek: 1,
                activityMETMinutes: nil,
                lastWorkoutAt: nil,
                todayCompleted: true
            )
        )
        let router = VoiceToolCallRouter(
            weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                repository: repository
            )
        )

        let unsupported = try await router.result(
            for: VoiceToolCall(callID: "unsupported", kind: .unsupported)
        )
        let invalidArguments = try await router.result(
            for: VoiceToolCall(callID: "invalid", kind: .invalidArguments)
        )

        #expect(
            String(data: unsupported.jsonData(), encoding: .utf8)
                == #"{"error":"unsupported_tool"}"#
        )
        #expect(
            String(data: invalidArguments.jsonData(), encoding: .utf8)
                == #"{"error":"invalid_arguments"}"#
        )
        #expect(await repository.weeklySummaryRequests.isEmpty)
    }

    @Test("maps generic repository failures to member data unavailable")
    func mapsGenericRepositoryFailure() async throws {
        let memberID = try MemberID(rawValue: "M-generic")
        let repository = RecordingMemberRepository(error: .generic)
        let router = VoiceToolCallRouter(
            weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                repository: repository
            )
        )

        let result = try await router.result(
            for: VoiceToolCall(
                callID: "generic-error",
                kind: .getMemberWeeklySummary(memberID: memberID)
            )
        )

        #expect(
            result.payload == .failure(.memberDataUnavailable)
        )
    }

    @Test("maps invalid summary data to invalid data")
    func mapsInvalidSummaryData() async throws {
        let memberID = try MemberID(rawValue: "M-invalid")
        let repository = RecordingMemberRepository(
            summary: ExerciseSummary(
                visitsThisWeek: -1,
                activityMETMinutes: nil,
                lastWorkoutAt: nil,
                todayCompleted: false
            )
        )
        let router = VoiceToolCallRouter(
            weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                repository: repository
            )
        )

        let result = try await router.result(
            for: VoiceToolCall(
                callID: "invalid-data",
                kind: .getMemberWeeklySummary(memberID: memberID)
            )
        )

        #expect(result.payload == .failure(.invalidData))
    }

    @Test("replays a completed call without querying the repository again")
    func replaysCompletedCallWithoutRequery() async throws {
        let memberID = try MemberID(rawValue: "M-cached")
        let repository = RecordingMemberRepository(
            summary: ExerciseSummary(
                visitsThisWeek: 4,
                activityMETMinutes: 120,
                lastWorkoutAt: nil,
                todayCompleted: true
            )
        )
        let router = VoiceToolCallRouter(
            weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                repository: repository
            )
        )
        let call = VoiceToolCall(
            callID: "cached-call",
            kind: .getMemberWeeklySummary(memberID: memberID)
        )

        let first = try await router.result(for: call)
        let replay = try await router.result(for: call)

        #expect(replay == first)
        #expect(await repository.weeklySummaryRequests == [memberID])
    }

    @Test("caches completed failures and does not replace the original call")
    func cachesCompletedFailureAndPreservesOriginalCall() async throws {
        let memberID = try MemberID(rawValue: "M-conflict")
        let repository = RecordingMemberRepository(
            summary: ExerciseSummary(
                visitsThisWeek: -1,
                activityMETMinutes: nil,
                lastWorkoutAt: nil,
                todayCompleted: false
            )
        )
        let router = VoiceToolCallRouter(
            weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                repository: repository
            )
        )
        let original = VoiceToolCall(
            callID: "same-call-id",
            kind: .getMemberWeeklySummary(memberID: memberID)
        )
        let conflicting = VoiceToolCall(
            callID: original.callID,
            kind: .unsupported
        )

        let first = try await router.result(for: original)
        let duplicate = try await router.result(for: conflicting)
        let replay = try await router.result(for: original)

        #expect(first.payload == .failure(.invalidData))
        #expect(duplicate.payload == .failure(.duplicateCall))
        #expect(replay == first)
        #expect(await repository.weeklySummaryRequests == [memberID])
    }

    @Test("pre-cancellation does not query or cache a result")
    func preCancellationDoesNotQueryOrCache() async throws {
        let memberID = try MemberID(rawValue: "M-pre-cancel")
        let repository = RecordingMemberRepository(
            summary: ExerciseSummary(
                visitsThisWeek: 1,
                activityMETMinutes: nil,
                lastWorkoutAt: nil,
                todayCompleted: false
            )
        )
        let router = VoiceToolCallRouter(
            weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                repository: repository
            )
        )
        let call = VoiceToolCall(
            callID: "pre-cancel-call",
            kind: .getMemberWeeklySummary(memberID: memberID)
        )
        let task = Task { () throws -> VoiceToolResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await router.result(for: call)
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await repository.weeklySummaryRequests.isEmpty)
        _ = try await router.result(for: call)
        #expect(await repository.weeklySummaryRequests == [memberID])
    }

    @Test("suspended cancellation wins over a repository failure and does not cache")
    func suspendedCancellationWinsAndDoesNotCache() async throws {
        let memberID = try MemberID(rawValue: "M-suspended-cancel")
        let repository = GatedMemberRepository()
        let router = VoiceToolCallRouter(
            weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                repository: repository
            )
        )
        let call = VoiceToolCall(
            callID: "suspended-cancel-call",
            kind: .getMemberWeeklySummary(memberID: memberID)
        )
        let task = Task { () throws -> VoiceToolResult in
            try await router.result(for: call)
        }

        await repository.waitUntilRequested()
        task.cancel()
        await repository.fail(with: RepositoryTestError.generic)

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        await repository.setNextSummary(
            ExerciseSummary(
                visitsThisWeek: 2,
                activityMETMinutes: nil,
                lastWorkoutAt: nil,
                todayCompleted: true
            )
        )
        _ = try await router.result(for: call)
        #expect(await repository.weeklySummaryRequests == [memberID, memberID])
    }

    @Test("cancellation after repository success wins and does not cache")
    func cancellationAfterRepositorySuccessDoesNotCache() async throws {
        let memberID = try MemberID(rawValue: "M-success-cancel")
        let repository = GatedMemberRepository()
        let router = VoiceToolCallRouter(
            weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                repository: repository
            )
        )
        let call = VoiceToolCall(
            callID: "success-cancel-call",
            kind: .getMemberWeeklySummary(memberID: memberID)
        )
        let task = Task { () throws -> VoiceToolResult in
            try await router.result(for: call)
        }

        await repository.waitUntilRequested()
        task.cancel()
        await repository.succeed(
            with: ExerciseSummary(
                visitsThisWeek: 3,
                activityMETMinutes: 240,
                lastWorkoutAt: nil,
                todayCompleted: true
            )
        )

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        await repository.setNextSummary(
            ExerciseSummary(
                visitsThisWeek: 4,
                activityMETMinutes: 360,
                lastWorkoutAt: nil,
                todayCompleted: true
            )
        )
        let result = try await router.result(for: call)

        #expect(result.payload != .failure(.duplicateCall))
        #expect(await repository.weeklySummaryRequests == [memberID, memberID])
    }
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
    private var immediateSummary: ExerciseSummary?
    private(set) var weeklySummaryRequests: [MemberID] = []

    func profile(for id: MemberID) async throws -> Member {
        throw RepositoryTestError.profileUnsupported
    }

    func weeklySummary(for id: MemberID) async throws -> ExerciseSummary {
        weeklySummaryRequests.append(id)
        for waiter in requestWaiters {
            waiter.resume()
        }
        requestWaiters.removeAll()

        if let immediateSummary {
            self.immediateSummary = nil
            return immediateSummary
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

    func fail(with error: RepositoryTestError) {
        pending?.resume(throwing: error)
        pending = nil
    }

    func succeed(with summary: ExerciseSummary) {
        pending?.resume(returning: summary)
        pending = nil
    }

    func setNextSummary(_ summary: ExerciseSummary) {
        immediateSummary = summary
    }
}

private enum RepositoryTestError: Error, Sendable {
    case generic
    case profileUnsupported
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
