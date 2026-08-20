import Foundation
import LumiApplication
import LumiDomain
import Testing

@Suite("Get member weekly summary use case")
struct GetMemberWeeklySummaryUseCaseTests {
    @Test("routes the exact MemberID and emits the minimum deterministic JSON")
    func routesExactMemberIDAndEmitsDeterministicJSON() async throws {
        let memberID = try MemberID(rawValue: "  M-001/exact  ")
        let lastWorkoutAt = Date(timeIntervalSince1970: 1_785_983_400)
        let repository = RecordingMemberRepository(
            summary: ExerciseSummary(
                visitsThisWeek: 2,
                activityMETMinutes: 580.5,
                lastWorkoutAt: lastWorkoutAt,
                todayCompleted: false
            )
        )
        let useCase = GetMemberWeeklySummaryUseCase(repository: repository)

        let result = try await useCase.execute(for: memberID)

        #expect(await repository.weeklySummaryRequests == [memberID])
        #expect(
            String(data: result.jsonData(), encoding: .utf8)
                == #"{"activity_met_minutes":580.5,"last_workout_at":"2026-08-06T02:30:00.000Z","today_completed":false,"visits_this_week":2}"#
        )
        #expect(result.jsonData() == result.jsonData())
    }

    @Test("encodes missing optional values as explicit null")
    func encodesMissingOptionalValuesAsNull() async throws {
        let memberID = try MemberID(rawValue: "M-002")
        let repository = RecordingMemberRepository(
            summary: ExerciseSummary(
                visitsThisWeek: 0,
                activityMETMinutes: nil,
                lastWorkoutAt: nil,
                todayCompleted: false
            )
        )
        let useCase = GetMemberWeeklySummaryUseCase(repository: repository)

        let result = try await useCase.execute(for: memberID)

        #expect(
            String(data: result.jsonData(), encoding: .utf8)
                == #"{"activity_met_minutes":null,"last_workout_at":null,"today_completed":false,"visits_this_week":0}"#
        )
    }

    @Test("normalizes an offset timestamp to UTC with fixed millisecond precision")
    func normalizesOffsetTimestampToUTC() async throws {
        let memberID = try MemberID(rawValue: "M-003")
        let formatter = ISO8601DateFormatter()
        let lastWorkoutAt = try #require(
            formatter.date(from: "2026-08-06T10:30:00+08:00")
        )
        let repository = RecordingMemberRepository(
            summary: ExerciseSummary(
                visitsThisWeek: 1,
                activityMETMinutes: nil,
                lastWorkoutAt: lastWorkoutAt,
                todayCompleted: true
            )
        )
        let useCase = GetMemberWeeklySummaryUseCase(repository: repository)

        let result = try await useCase.execute(for: memberID)

        #expect(
            String(data: result.jsonData(), encoding: .utf8)
                == #"{"activity_met_minutes":null,"last_workout_at":"2026-08-06T02:30:00.000Z","today_completed":true,"visits_this_week":1}"#
        )
    }

    @Test("maps every generic repository failure to one fixed redacted error")
    func mapsGenericRepositoryFailureToFixedRedactedError() async throws {
        let memberID = try MemberID(rawValue: "member-secret-marker")
        let marker = "repository-sensitive-marker"
        let repository = RecordingMemberRepository(
            error: .generic(marker: marker)
        )
        let useCase = GetMemberWeeklySummaryUseCase(repository: repository)

        do {
            _ = try await useCase.execute(for: memberID)
            Issue.record("The use case must fail when the repository fails")
        } catch let error as GetMemberWeeklySummaryError {
            #expect(error == .repositoryUnavailable)
            #expect(error.description == "repositoryUnavailable")
            #expect(error.debugDescription == "repositoryUnavailable")
            #expect(!String(describing: error).contains(marker))
            #expect(!String(reflecting: error).contains(marker))
            #expect(Array(error.customMirror.children).isEmpty)
        }
    }

    @Test("fixed application errors expose no payload")
    func fixedApplicationErrorsExposeNoPayload() {
        for error in [
            GetMemberWeeklySummaryError.repositoryUnavailable,
            GetMemberWeeklySummaryError.invalidData
        ] {
            #expect(error.description == String(describing: error))
            #expect(error.debugDescription == error.description)
            #expect(!String(reflecting: error).contains("member-secret-marker"))
            #expect(Array(error.customMirror.children).isEmpty)
        }
    }

    @Test("rejects non-finite or negative summary values")
    func rejectsInvalidSummaryValues() async throws {
        let memberID = try MemberID(rawValue: "M-004")
        let invalidSummaries = [
            ExerciseSummary(
                visitsThisWeek: -1,
                activityMETMinutes: nil,
                lastWorkoutAt: nil,
                todayCompleted: false
            ),
            ExerciseSummary(
                visitsThisWeek: 1,
                activityMETMinutes: -.infinity,
                lastWorkoutAt: nil,
                todayCompleted: false
            ),
            ExerciseSummary(
                visitsThisWeek: 1,
                activityMETMinutes: .nan,
                lastWorkoutAt: nil,
                todayCompleted: false
            ),
            ExerciseSummary(
                visitsThisWeek: 1,
                activityMETMinutes: nil,
                lastWorkoutAt: Date(timeIntervalSinceReferenceDate: .infinity),
                todayCompleted: false
            )
        ]

        for summary in invalidSummaries {
            let repository = RecordingMemberRepository(summary: summary)
            let useCase = GetMemberWeeklySummaryUseCase(repository: repository)

            await #expect(throws: GetMemberWeeklySummaryError.invalidData) {
                try await useCase.execute(for: memberID)
            }
        }
    }

    @Test("pre-cancellation does not call the repository")
    func preCancellationDoesNotCallRepository() async throws {
        let memberID = try MemberID(rawValue: "M-005")
        let repository = RecordingMemberRepository(
            summary: ExerciseSummary(
                visitsThisWeek: 1,
                activityMETMinutes: nil,
                lastWorkoutAt: nil,
                todayCompleted: false
            )
        )
        let useCase = GetMemberWeeklySummaryUseCase(repository: repository)
        let task = Task { () throws -> MemberWeeklySummaryToolResult in
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await useCase.execute(for: memberID)
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await repository.weeklySummaryRequests.isEmpty)
    }

    @Test("cancellation wins when a generic repository failure races it")
    func cancellationWinsOverGenericRepositoryFailure() async throws {
        let memberID = try MemberID(rawValue: "M-006")
        let repository = GatedMemberRepository()
        let useCase = GetMemberWeeklySummaryUseCase(repository: repository)
        let task = Task { () throws -> MemberWeeklySummaryToolResult in
            try await useCase.execute(for: memberID)
        }

        await repository.waitUntilRequested()
        task.cancel()
        await repository.fail(
            with: TestRepositoryError.generic(marker: "late-sensitive-marker")
        )

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("success after cancellation is still reported as cancellation")
    func successAfterCancellationIsStillCancellation() async throws {
        let memberID = try MemberID(rawValue: "M-007")
        let repository = GatedMemberRepository()
        let useCase = GetMemberWeeklySummaryUseCase(repository: repository)
        let task = Task { () throws -> MemberWeeklySummaryToolResult in
            try await useCase.execute(for: memberID)
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
    }
}

private actor RecordingMemberRepository: MemberRepository {
    private let outcome: Outcome
    private(set) var weeklySummaryRequests: [MemberID] = []

    init(summary: ExerciseSummary) {
        outcome = .success(summary)
    }

    init(error: TestRepositoryError) {
        outcome = .failure(error)
    }

    func profile(for id: MemberID) async throws -> Member {
        throw TestRepositoryError.profileUnsupported
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
        case failure(TestRepositoryError)
    }
}

private actor GatedMemberRepository: MemberRepository {
    private var pending: CheckedContinuation<ExerciseSummary, any Error>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func profile(for id: MemberID) async throws -> Member {
        throw TestRepositoryError.profileUnsupported
    }

    func weeklySummary(for id: MemberID) async throws -> ExerciseSummary {
        for waiter in requestWaiters {
            waiter.resume()
        }
        requestWaiters.removeAll()

        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
        }
    }

    func waitUntilRequested() async {
        guard pending == nil else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func fail(with error: any Error) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(throwing: error)
    }

    func succeed(with summary: ExerciseSummary) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: summary)
    }
}

private enum TestRepositoryError: Error, Sendable {
    case generic(marker: String)
    case profileUnsupported
}
