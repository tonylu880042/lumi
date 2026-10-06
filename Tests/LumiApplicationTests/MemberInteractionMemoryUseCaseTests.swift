import Foundation
import LumiApplication
import LumiDomain
import Testing

@Suite("Member interaction memory use cases")
struct MemberInteractionMemoryUseCaseTests {
    @Test("loads a policy snapshot only when independent memory consent is enabled")
    func loadsConsentedSnapshot() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake(
            consent: .enabled(consentedAt: date("2026-09-01T09:00:00+08:00")),
            events: [
                MemberMemoryEvent(
                    eventID: "meeting-1",
                    interactionID: "session-1",
                    kind: .meeting,
                    source: .lumiObserved,
                    recordedAt: date("2026-09-18T09:00:00+08:00"),
                    exerciseDisclosure: nil
                )
            ]
        )

        let result = try await LoadMemberMemoryUseCase(store: store).execute(
            for: memberID,
            at: date("2026-09-18T12:00:00+08:00")
        )

        guard case let .available(context) = result else {
            Issue.record("Expected an available memory context")
            return
        }
        #expect(context.snapshot.hasSeenToday)
        #expect(context.snapshot.weeklyMeetingDayCount == 1)
        #expect(context.snapshot.isDepartureEncouragementEligible)
        #expect(context.revision == 7)
    }

    @Test("separate completed greetings on the same day still contribute one weekly count")
    func deduplicatesSameDayGreetingsInLoadedCount() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake(
            consent: .enabled(consentedAt: date("2026-09-01T09:00:00+08:00")),
            events: []
        )
        let recorder = RecordMemberMeetingUseCase(store: store)
        let first = try await recorder.execute(
            for: memberID, sessionID: "morning",
            at: date("2026-10-01T09:00:00+08:00"), expectedRevision: 7
        )
        _ = try await recorder.execute(
            for: memberID, sessionID: "afternoon",
            at: date("2026-10-01T14:00:00+08:00"), expectedRevision: first.revision
        )
        let result = try await LoadMemberMemoryUseCase(store: store).execute(
            for: memberID, at: date("2026-10-01T15:00:00+08:00")
        )
        guard case let .available(context) = result else {
            Issue.record("Expected consented counts")
            return
        }
        #expect(context.snapshot.weeklyMeetingDayCount == 1)
    }

    @Test("does not expose events when the member has not granted memory consent")
    func refusesUnconsentedSnapshot() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake(consent: .disabled, events: [])

        let result = try await LoadMemberMemoryUseCase(store: store).execute(
            for: memberID,
            at: date("2026-09-18T12:00:00+08:00")
        )

        #expect(result == .disabled)
        #expect(await store.loadedBatchCount == 0)
    }

    @Test("records only an explicit completed-today disclosure")
    func recordsPersistentExerciseDisclosure() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake(
            consent: .enabled(consentedAt: date("2026-09-01T09:00:00+08:00")),
            events: []
        )

        let recorded = try await RecordMemberExerciseDisclosureUseCase(store: store)
            .execute(
                for: memberID,
                disclosure: .completedToday,
                interactionID: "exercise:2026-09-18",
                at: date("2026-09-18T12:00:00+08:00"),
                expectedRevision: 7
            )

        #expect(recorded.outcome == .appended)
        let event = try #require(await store.events.first)
        #expect(event.kind == .exerciseDisclosure)
        #expect(event.source == .memberReported)
        #expect(event.exerciseDisclosure == .completedToday)
    }

    @Test("session-only exercise disclosures never reach the persistent store")
    func skipsSessionOnlyDisclosure() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake(
            consent: .enabled(consentedAt: date("2026-09-01T09:00:00+08:00")),
            events: []
        )

        let recorded = try await RecordMemberExerciseDisclosureUseCase(store: store)
            .execute(
                for: memberID,
                disclosure: .justCompleted,
                interactionID: "session-1",
                at: date("2026-09-18T12:00:00+08:00"),
                expectedRevision: 7
            )

        #expect(recorded.outcome == .ignored)
        #expect(await store.events.isEmpty)
    }

    @Test("meeting writes use the observed source and can be rejected as stale")
    func recordsMeetingWithRevisionGuard() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake(
            consent: .enabled(consentedAt: date("2026-09-01T09:00:00+08:00")),
            events: [],
            acceptedRevision: 8
        )

        let recorded = try await RecordMemberMeetingUseCase(store: store).execute(
            for: memberID,
            sessionID: "session-1",
            at: date("2026-09-18T12:00:00+08:00"),
            expectedRevision: 7
        )

        #expect(recorded.outcome == .rejected)
        #expect(await store.events.isEmpty)
    }

    @Test("a successful meeting write returns the revision for a second write")
    func chainsMeetingAndExerciseWrites() async throws {
        let memberID = try MemberID(rawValue: "member-memory")
        let store = MemoryStoreFake(
            consent: .enabled(consentedAt: date("2026-09-01T09:00:00+08:00")),
            events: []
        )
        let meeting = try await RecordMemberMeetingUseCase(store: store).execute(
            for: memberID,
            sessionID: "session-1",
            at: date("2026-09-18T12:00:00+08:00"),
            expectedRevision: 7
        )
        let exercise = try await RecordMemberExerciseDisclosureUseCase(store: store)
            .execute(
                for: memberID,
                disclosure: .completedToday,
                interactionID: "session-1-exercise",
                at: date("2026-09-18T12:01:00+08:00"),
                expectedRevision: meeting.revision
            )

        #expect(meeting.outcome == .appended)
        #expect(meeting.revision == 8)
        #expect(exercise.outcome == .appended)
        #expect(exercise.revision == 9)
        #expect(await store.events.count == 2)
    }
}

private actor MemoryStoreFake: MemberInteractionMemoryStore {
    let consent: MemberMemoryConsentStatus
    private(set) var events: [MemberMemoryEvent]
    private(set) var revision: UInt64
    let acceptedRevisionOverride: UInt64?
    private(set) var loadedBatchCount = 0

    init(
        consent: MemberMemoryConsentStatus,
        events: [MemberMemoryEvent],
        revision: UInt64 = 7,
        acceptedRevision: UInt64? = nil
    ) {
        self.consent = consent
        self.events = events
        self.revision = revision
        self.acceptedRevisionOverride = acceptedRevision
    }

    func consentStatus(for _: MemberID) async throws -> MemberMemoryConsentStatus {
        consent
    }

    func loadBatch(for _: MemberID, at _: Date) async throws -> MemberMemoryEventBatch {
        loadedBatchCount += 1
        return MemberMemoryEventBatch(events: events, revision: revision)
    }

    func append(
        _ event: MemberMemoryEvent,
        for _: MemberID,
        expectedRevision: UInt64
    ) async throws -> MemberMemoryAppendResult {
        guard expectedRevision == (acceptedRevisionOverride ?? revision) else {
            return MemberMemoryAppendResult(
                outcome: .rejected,
                revision: revision
            )
        }
        events.append(event)
        revision &+= 1
        return MemberMemoryAppendResult(outcome: .appended, revision: revision)
    }

    func setConsent(
        for _: MemberID,
        status _: MemberMemoryConsentStatus
    ) async throws {}

    func clearMemory(for _: MemberID) async throws {}

    func managementProfiles() async throws -> [MemberMemoryManagementProfile] { [] }
}

private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
    return formatter.date(from: value)!
}
