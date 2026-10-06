import Foundation
import LumiApplication
import LumiDomain
import Testing

@Suite("Member exercise disclosure voice tool")
struct MemberExerciseDisclosureToolTests {
    @Test("records a bounded completed-today disclosure for the session member")
    func recordsCompletedToday() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake()
        let session = MemberInteractionMemorySession(
            memberID: memberID,
            sessionID: "session-1",
            initialRevision: 7,
            store: store
        )
        let router = VoiceToolCallRouter(
            memberID: memberID,
            weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                repository: EmptyMemberRepository()
            ),
            memorySession: session,
            now: { Date(timeIntervalSince1970: 1_789_000_000) }
        )

        let result = try await router.result(
            for: VoiceToolCall(
                callID: "exercise-call",
                kind: .recordExerciseDisclosure(.completedToday)
            )
        )

        #expect(
            String(data: result.jsonData(), encoding: .utf8)
                == #"{"exercise_state":"completed_today","persistence":"day","status":"recorded"}"#
        )
        #expect(await store.events.count == 1)
        #expect(await store.events.first?.exerciseDisclosure == .completedToday)
    }

    @Test("repeated calls with different provider IDs remain one bounded event")
    func deduplicatesAcrossProviderCallIDs() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake()
        let session = MemberInteractionMemorySession(
            memberID: memberID,
            sessionID: "session-1",
            initialRevision: 7,
            store: store
        )
        let router = VoiceToolCallRouter(
            memberID: memberID,
            weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                repository: EmptyMemberRepository()
            ),
            memorySession: session
        )

        _ = try await router.result(
            for: VoiceToolCall(
                callID: "first-call",
                kind: .recordExerciseDisclosure(.completedToday)
            )
        )
        let replay = try await router.result(
            for: VoiceToolCall(
                callID: "second-call",
                kind: .recordExerciseDisclosure(.completedToday)
            )
        )

        #expect(replay.payload == .exerciseDisclosureRecorded(.completedToday))
        #expect(await store.events.count == 1)
    }

    @Test("serializes a greeting write and an exercise write in one session")
    func serializesSessionWrites() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake()
        let session = MemberInteractionMemorySession(
            memberID: memberID,
            sessionID: "session-unique",
            initialRevision: 7,
            store: store
        )

        async let meeting = session.recordMeeting(
            at: Date(timeIntervalSince1970: 1_789_000_000)
        )
        async let exercise = session.recordExerciseDisclosure(
            .completedToday,
            at: Date(timeIntervalSince1970: 1_789_000_001)
        )
        let results = try await (meeting, exercise)

        #expect(results.0.outcome == .appended)
        #expect(results.1.outcome == .appended)
        #expect(await store.events.count == 2)
        #expect(await store.events.map(\.interactionID).contains("session-unique:exercise:completed_today"))
    }

    @Test("completed-today disclosure expires after the Taipei day boundary")
    func completedTodayExpiresAfterTaipeiMidnight() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake()
        let session = MemberInteractionMemorySession(
            memberID: memberID,
            sessionID: "midnight-session",
            initialRevision: 7,
            store: store
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let beforeMidnight = calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: 2026,
                month: 9,
                day: 20,
                hour: 23,
                minute: 59
            )
        )!
        let afterMidnight = calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: 2026,
                month: 9,
                day: 21,
                hour: 0,
                minute: 1
            )
        )!

        _ = try await session.recordExerciseDisclosure(
            .completedToday,
            at: beforeMidnight
        )

        #expect(
            await session.currentExerciseState(at: beforeMidnight)
                == .completedToday
        )
        #expect(await session.currentExerciseState(at: afterMidnight) == nil)

        _ = try await session.recordExerciseDisclosure(
            .completedToday,
            at: afterMidnight
        )
        #expect(await session.currentExerciseState(at: afterMidnight) == nil)
    }

    @Test("session-only disclosures update conversation context without persistence")
    func sessionOnlyDisclosuresStayInConversationContext() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake()
        let session = MemberInteractionMemorySession(
            memberID: memberID,
            sessionID: "session-only",
            initialRevision: 7,
            store: store
        )
        let changes = DisclosureChangeRecorder()
        let router = VoiceToolCallRouter(
            memberID: memberID,
            memorySession: session,
            memoryContextDidChange: { disclosure, recordedAt in
                await changes.record(disclosure, at: recordedAt)
            }
        )

        for (index, disclosure) in [
            MemberExerciseDisclosure.preparing,
            .justCompleted,
        ].enumerated() {
            let result = try await router.result(
                for: VoiceToolCall(
                    callID: "session-only-\(index)",
                    kind: .recordExerciseDisclosure(disclosure)
                )
            )
            #expect(result.payload == .exerciseDisclosureRecorded(disclosure))
            #expect(
                String(data: result.jsonData(), encoding: .utf8)?
                    .contains(#""persistence":"session""#) == true
            )
            #expect(
                String(data: result.jsonData(), encoding: .utf8)?
                    .contains(#""status":"session_only""#) == true
            )
        }

        #expect(await store.events.isEmpty)
        #expect(await changes.values == [.preparing, .justCompleted])
        #expect(await session.currentExerciseState() == .justCompleted)
    }

    @Test("correction removes a persistent completion and clears session context")
    func correctionRemovesPersistentAndSessionState() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake()
        let session = MemberInteractionMemorySession(
            memberID: memberID,
            sessionID: "correction-session",
            initialRevision: 7,
            store: store
        )
        let changes = DisclosureChangeRecorder()
        let router = VoiceToolCallRouter(
            memberID: memberID,
            memorySession: session,
            now: { Date(timeIntervalSince1970: 1_789_000_000) },
            memoryContextDidChange: { disclosure, recordedAt in
                await changes.record(disclosure, at: recordedAt)
            }
        )

        _ = try await router.result(
            for: VoiceToolCall(
                callID: "persist-completion",
                kind: .recordExerciseDisclosure(.completedToday)
            )
        )
        _ = try await router.result(
            for: VoiceToolCall(
                callID: "session-just-completed",
                kind: .recordExerciseDisclosure(.justCompleted)
            )
        )
        let correction = try await router.result(
            for: VoiceToolCall(
                callID: "correct-completion",
                kind: .correctMemberExerciseDisclosure
            )
        )

        #expect(correction.payload == .exerciseDisclosureCorrected)
        #expect(
            String(data: correction.jsonData(), encoding: .utf8)
                == #"{"status":"exercise_disclosure_corrected"}"#
        )
        #expect(await store.events.isEmpty)
        #expect(await session.currentExerciseState() == nil)
        #expect(await changes.values == [.completedToday, .justCompleted, nil])
        #expect(
            await changes.recordedAts == [
                Date(timeIntervalSince1970: 1_789_000_000),
                Date(timeIntervalSince1970: 1_789_000_000),
                Date(timeIntervalSince1970: 1_789_000_000),
            ]
        )
    }

    @Test("correction reports not found while still clearing session-only context")
    func correctionNotFoundClearsSessionState() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake()
        let session = MemberInteractionMemorySession(
            memberID: memberID,
            sessionID: "not-found-session",
            initialRevision: 7,
            store: store
        )
        let changes = DisclosureChangeRecorder()
        let router = VoiceToolCallRouter(
            memberID: memberID,
            memorySession: session,
            memoryContextDidChange: { disclosure, recordedAt in
                await changes.record(disclosure, at: recordedAt)
            }
        )

        _ = try await router.result(
            for: VoiceToolCall(
                callID: "preparing",
                kind: .recordExerciseDisclosure(.preparing)
            )
        )
        let correction = try await router.result(
            for: VoiceToolCall(
                callID: "correct-missing",
                kind: .correctMemberExerciseDisclosure
            )
        )

        #expect(correction.payload == .exerciseDisclosureCorrectionNotFound)
        #expect(
            String(data: correction.jsonData(), encoding: .utf8)
                == #"{"status":"no_current_exercise_disclosure"}"#
        )
        #expect(await session.currentExerciseState() == nil)
        #expect(await changes.values == [.preparing, nil])
    }

    @Test("a stale session revision fails closed without updating provider context")
    func staleRevisionRejectsDisclosureAndCorrection() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake()
        let session = MemberInteractionMemorySession(
            memberID: memberID,
            sessionID: "stale-session",
            initialRevision: 7,
            store: store
        )
        let changes = DisclosureChangeRecorder()
        let router = VoiceToolCallRouter(
            memberID: memberID,
            memorySession: session,
            memoryContextDidChange: { disclosure, recordedAt in
                await changes.record(disclosure, at: recordedAt)
            }
        )
        await store.advanceRevision()

        let disclosure = try await router.result(
            for: VoiceToolCall(
                callID: "stale-disclosure",
                kind: .recordExerciseDisclosure(.completedToday)
            )
        )
        let correction = try await router.result(
            for: VoiceToolCall(
                callID: "stale-correction",
                kind: .correctMemberExerciseDisclosure
            )
        )

        #expect(disclosure.payload == .failure(.memberMemoryUnavailable))
        #expect(correction.payload == .failure(.memberMemoryUnavailable))
        #expect(await store.events.isEmpty)
        #expect(await changes.values.isEmpty)
        #expect(await session.isValid() == false)
    }
}

private actor MemoryStoreFake: MemberInteractionMemoryStore {
    private(set) var events: [MemberMemoryEvent] = []
    private var revision: UInt64 = 7

    func consentStatus(for _: MemberID) async throws -> MemberMemoryConsentStatus {
        .enabled(consentedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func loadBatch(for _: MemberID, at _: Date) async throws -> MemberMemoryEventBatch {
        MemberMemoryEventBatch(events: events, revision: revision)
    }

    func append(
        _ event: MemberMemoryEvent,
        for _: MemberID,
        expectedRevision: UInt64
    ) async throws -> MemberMemoryAppendResult {
        guard expectedRevision == revision else {
            return MemberMemoryAppendResult(outcome: .rejected, revision: revision)
        }
        guard !events.contains(where: { $0.eventID == event.eventID }) else {
            return MemberMemoryAppendResult(outcome: .duplicate, revision: revision)
        }
        events.append(event)
        revision &+= 1
        return MemberMemoryAppendResult(outcome: .appended, revision: revision)
    }

    func correctExerciseDisclosure(
        for _: MemberID,
        at _: Date,
        expectedRevision: UInt64
    ) async throws -> MemberMemoryCorrectionResult {
        guard expectedRevision == revision else {
            return MemberMemoryCorrectionResult(
                outcome: .rejected,
                revision: revision
            )
        }
        guard let index = events.lastIndex(where: {
            $0.kind == .exerciseDisclosure
                && $0.exerciseDisclosure == .completedToday
        }) else {
            return MemberMemoryCorrectionResult(
                outcome: .notFound,
                revision: revision
            )
        }
        events.remove(at: index)
        revision &+= 1
        return MemberMemoryCorrectionResult(
            outcome: .corrected,
            revision: revision
        )
    }

    func advanceRevision() {
        revision &+= 1
    }

    func setConsent(for _: MemberID, status _: MemberMemoryConsentStatus) async throws {}
    func clearMemory(for _: MemberID) async throws {}
}

private actor DisclosureChangeRecorder {
    private(set) var values: [MemberExerciseDisclosure?] = []
    private(set) var recordedAts: [Date] = []

    func record(_ disclosure: MemberExerciseDisclosure?, at recordedAt: Date) {
        values.append(disclosure)
        recordedAts.append(recordedAt)
    }
}

private struct EmptyMemberRepository: MemberRepository {
    func profile(for id: MemberID) async throws -> Member {
        Member(id: id, displayName: "測試會員")
    }

    func weeklySummary(for _: MemberID) async throws -> ExerciseSummary {
        ExerciseSummary(
            visitsThisWeek: 0,
            activityMETMinutes: nil,
            lastWorkoutAt: nil,
            todayCompleted: false
        )
    }
}
