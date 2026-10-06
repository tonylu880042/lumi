import Foundation
import LumiDomain
import Testing

@Suite("Member interaction memory policy")
struct MemberInteractionMemoryTests {
    private let timeZone = TimeZone(identifier: "Asia/Taipei")!

    @Test("first arrival includes today's encounter without writing it into history")
    func arrivalCountIncludesCurrentEncounter() {
        let now = date("2026-10-01T09:00:00+08:00")
        let events = [
            meeting("monday", "2026-09-28T09:00:00+08:00"),
            meeting("monday-repeat", "2026-09-28T10:00:00+08:00"),
            meeting("tuesday", "2026-09-29T09:00:00+08:00")
        ]
        let snapshot = MemberInteractionMemoryPolicy().snapshot(from: events, at: now)
        #expect(snapshot.weeklyMeetingDayCount == 2)
        #expect(snapshot.arrivalWeeklyMeetingDayCount == 3)
        #expect(snapshot.firstMeetingTodayAt == nil)
        #expect(MemberInteractionMemoryPolicy().snapshot(from: [], at: now)
            .arrivalWeeklyMeetingDayCount == 1)
    }

    @Test("a saved same-day greeting prevents repeating the weekly arrival announcement")
    func revisitDoesNotRepeatArrivalCount() {
        let events = [meeting("first", "2026-10-01T09:00:00+08:00")]
        let policy = MemberInteractionMemoryPolicy()
        for seconds in [0.0, 1799.0, 1800.0] {
            let snapshot = policy.snapshot(from: events,
                at: date("2026-10-01T09:00:00+08:00").addingTimeInterval(seconds))
            #expect(snapshot.arrivalWeeklyMeetingDayCount == nil)
            #expect(snapshot.weeklyMeetingDayCount == 1)
        }
    }

    @Test("arrival count resets with the Taipei week and fails closed for invalid time")
    func arrivalWeekBoundaryAndInvalidTime() {
        let events = [meeting("sunday", "2026-10-04T23:59:59+08:00")]
        let policy = MemberInteractionMemoryPolicy()
        #expect(policy.snapshot(from: events, at: date("2026-10-05T00:00:00+08:00"))
            .arrivalWeeklyMeetingDayCount == 1)
        #expect(policy.snapshot(from: events, at: Date(timeIntervalSince1970: .nan))
            .arrivalWeeklyMeetingDayCount == nil)
    }

    @Test("departure eligibility starts thirty minutes after the earliest observed record today")
    func departureEligibilityUsesFirstRecord() {
        let policy = MemberInteractionMemoryPolicy()
        let events = [
            meeting("later", "2026-10-02T09:20:00+08:00"),
            meeting("first", "2026-10-02T09:00:00+08:00"),
            meeting("repeat", "2026-10-02T09:25:00+08:00")
        ]
        #expect(!policy.snapshot(
            from: events, at: date("2026-10-02T09:29:59+08:00")
        ).isDepartureEncouragementEligible)
        let eligible = policy.snapshot(
            from: events, at: date("2026-10-02T09:30:00+08:00")
        )
        #expect(eligible.isDepartureEncouragementEligible)
        #expect(eligible.weeklyMeetingDayCount == 1)
        #expect(policy.snapshot(
            from: events, at: date("2026-10-02T10:00:00+08:00")
        ).isDepartureEncouragementEligible)
    }

    @Test("departure eligibility requires a valid observed record on the current Taipei day")
    func departureEligibilityFailsClosedWithoutTodaysRecord() {
        let policy = MemberInteractionMemoryPolicy()
        let now = date("2026-10-02T00:20:00+08:00")
        let reported = MemberMemoryEvent(
            eventID: "report", interactionID: "report", kind: .meeting,
            source: .memberReported,
            recordedAt: date("2026-10-02T00:00:00+08:00"),
            exerciseDisclosure: nil
        )
        let invalid = MemberMemoryEvent(
            eventID: "invalid", interactionID: "invalid", kind: .meeting,
            source: .lumiObserved, recordedAt: Date(timeIntervalSince1970: .nan),
            exerciseDisclosure: nil
        )
        for events in [
            [], [meeting("yesterday", "2026-10-01T23:00:00+08:00")],
            [meeting("future", "2026-10-02T01:00:00+08:00")],
            [reported], [invalid]
        ] {
            #expect(!policy.snapshot(
                from: events, at: now
            ).isDepartureEncouragementEligible)
        }
        #expect(!policy.snapshot(
            from: [meeting("first", "2026-10-02T00:00:00+08:00")],
            at: Date(timeIntervalSince1970: .nan)
        ).isDepartureEncouragementEligible)
        #expect(policy.snapshot(
            from: [meeting("first", "2026-10-01T16:00:00Z")],
            at: date("2026-10-02T00:30:00+08:00")
        ).isDepartureEncouragementEligible)
    }

    @Test("calendar week counts each observed Taipei date once, not the rolling seven days")
    func countsObservedCalendarWeek() {
        let snapshot = MemberInteractionMemoryPolicy().snapshot(
            from: [
                meeting("last-sunday", "2026-09-27T23:59:59+08:00"),
                meeting("monday", "2026-09-28T00:00:00+08:00"),
                meeting("morning", "2026-10-01T09:00:00+08:00"),
                meeting("afternoon", "2026-10-01T11:00:00+08:00"),
                meeting("future", "2026-10-01T13:00:00+08:00")
            ],
            at: date("2026-10-01T12:00:00+08:00")
        )

        #expect(snapshot.weeklyMeetingDayCount == 2)
        #expect(snapshot.recentMeetingDayCount == 3)
    }

    @Test("calendar week resets at Monday midnight in Taipei even across a year")
    func resetsObservedWeekAtMonday() {
        let events = [
            meeting("sunday", "2026-01-04T15:59:59Z"),
            meeting("monday", "2026-01-04T16:00:00Z"),
            meeting("monday-again", "2026-01-04T16:01:00Z")
        ]
        let policy = MemberInteractionMemoryPolicy()
        #expect(policy.snapshot(
            from: events,
            at: date("2026-01-04T23:59:59+08:00")
        ).weeklyMeetingDayCount == 1)
        #expect(policy.snapshot(
            from: events,
            at: date("2026-01-05T00:05:00+08:00")
        ).weeklyMeetingDayCount == 1)
        #expect(policy.snapshot(
            from: [meeting("december", "2025-12-29T09:00:00+08:00")],
            at: date("2026-01-01T12:00:00+08:00")
        ).weeklyMeetingDayCount == 1)
    }

    @Test("only finite, past, observed meeting events contribute to the weekly count")
    func filtersWeeklyCountEvidence() {
        let reported = MemberMemoryEvent(
            eventID: "report", interactionID: "report", kind: .meeting,
            source: .memberReported,
            recordedAt: date("2026-09-29T09:00:00+08:00"),
            exerciseDisclosure: nil
        )
        let invalid = MemberMemoryEvent(
            eventID: "invalid", interactionID: "invalid", kind: .meeting,
            source: .lumiObserved, recordedAt: Date(timeIntervalSince1970: .nan),
            exerciseDisclosure: nil
        )
        let disclosure = MemberMemoryEvent(
            eventID: "exercise", interactionID: "exercise", kind: .exerciseDisclosure,
            source: .memberReported,
            recordedAt: date("2026-09-30T09:00:00+08:00"),
            exerciseDisclosure: .completedToday
        )
        let policy = MemberInteractionMemoryPolicy()
        #expect(policy.snapshot(
            from: [reported, invalid, disclosure],
            at: date("2026-10-01T12:00:00+08:00")
        ).weeklyMeetingDayCount == 0)
        #expect(policy.snapshot(
            from: [meeting("valid", "2026-10-01T09:00:00+08:00")],
            at: Date(timeIntervalSince1970: .nan)
        ).weeklyMeetingDayCount == 0)
    }

    @Test("counts distinct meeting days in the inclusive seven-day window")
    func countsDistinctMeetingDays() throws {
        let now = date("2026-09-18T12:00:00+08:00")
        let events = [
            meeting("a", "2026-09-18T09:00:00+08:00"),
            meeting("b", "2026-09-18T11:00:00+08:00"),
            meeting("c", "2026-09-14T10:00:00+08:00"),
            meeting("d", "2026-09-12T10:00:00+08:00"),
            meeting("e", "2026-09-11T10:00:00+08:00")
        ]

        let snapshot = MemberInteractionMemoryPolicy().snapshot(
            from: events,
            at: now,
            timeZone: timeZone
        )

        #expect(snapshot.hasSeenToday)
        #expect(snapshot.recentMeetingDayCount == 3)
        #expect(snapshot.primaryHighlight == .seenToday)
    }

    @Test("uses Asia/Taipei calendar days around midnight")
    func usesStoreCalendarDayAtMidnight() {
        let now = date("2026-09-18T00:05:00+08:00")
        let events = [
            meeting("before-midnight", "2026-09-17T15:59:59Z"),
            meeting("after-midnight", "2026-09-17T16:00:00Z")
        ]

        let snapshot = MemberInteractionMemoryPolicy().snapshot(
            from: events,
            at: now,
            timeZone: timeZone
        )

        #expect(snapshot.hasSeenToday)
        #expect(snapshot.recentMeetingDayCount == 2)
    }

    @Test("requires fourteen full store days for long absence")
    func longAbsenceBoundary() {
        let now = date("2026-09-18T12:00:00+08:00")
        let policy = MemberInteractionMemoryPolicy()

        let thirteenDays = policy.snapshot(
            from: [meeting("recent", "2026-09-05T10:00:00+08:00")],
            at: now,
            timeZone: timeZone
        )
        let fourteenDays = policy.snapshot(
            from: [meeting("old", "2026-09-04T10:00:00+08:00")],
            at: now,
            timeZone: timeZone
        )

        #expect(!thirteenDays.isLongAbsent)
        #expect(thirteenDays.primaryHighlight == nil)
        #expect(fourteenDays.isLongAbsent)
        #expect(fourteenDays.primaryHighlight == .longAbsent)
    }

    @Test("marks a member as long absent before the new meeting is recorded")
    func marksLongAbsenceFromPreviousMeeting() throws {
        let now = date("2026-09-18T12:00:00+08:00")
        let events = [meeting("old", "2026-09-04T10:00:00+08:00")]

        let snapshot = MemberInteractionMemoryPolicy().snapshot(
            from: events,
            at: now,
            timeZone: timeZone
        )

        #expect(snapshot.isLongAbsent)
        #expect(snapshot.primaryHighlight == .longAbsent)
        #expect(snapshot.lastMeetingAt == date("2026-09-04T10:00:00+08:00"))
    }

    @Test("ignores future events and events outside the ninety-day retention window")
    func ignoresFutureAndExpiredEvents() throws {
        let now = date("2026-09-18T12:00:00+08:00")
        let events = [
            meeting("expired", "2026-06-19T11:59:59+08:00"),
            meeting("future", "2026-09-19T10:00:00+08:00")
        ]

        let snapshot = MemberInteractionMemoryPolicy().snapshot(
            from: events,
            at: now,
            timeZone: timeZone
        )

        #expect(snapshot.lastMeetingAt == nil)
        #expect(snapshot.recentMeetingDayCount == 0)
        #expect(snapshot.primaryHighlight == nil)
        #expect(!snapshot.isLongAbsent)
    }

    @Test("keeps the inclusive retention boundary and excludes the next older day")
    func retentionBoundary() {
        let now = date("2026-09-18T12:00:00+08:00")
        let events = [
            meeting("boundary", "2026-06-20T12:00:00+08:00"),
            meeting("expired", "2026-06-19T23:59:59+08:00")
        ]

        let snapshot = MemberInteractionMemoryPolicy().snapshot(
            from: events,
            at: now,
            timeZone: timeZone
        )

        #expect(snapshot.lastMeetingAt == date("2026-06-20T12:00:00+08:00"))
        #expect(snapshot.isLongAbsent)
        #expect(snapshot.primaryHighlight == .longAbsent)
    }

    @Test("exposes a same-day completion but keeps just-completed session scoped")
    func exerciseDisclosureScopes() {
        #expect(MemberExerciseDisclosure.preparing.persistenceScope == .session)
        #expect(MemberExerciseDisclosure.justCompleted.persistenceScope == .session)
        #expect(MemberExerciseDisclosure.completedToday.persistenceScope == .day)
    }

    @Test("only the completed-today disclosure is a persistent event")
    func persistentExerciseDisclosure() {
        #expect(MemberExerciseDisclosure.preparing.isPersistent == false)
        #expect(MemberExerciseDisclosure.justCompleted.isPersistent == false)
        #expect(MemberExerciseDisclosure.completedToday.isPersistent)
    }

    @Test("reads completed-today disclosure only on the same store day")
    func readsCompletedTodayDisclosureWithinDay() {
        let policy = MemberInteractionMemoryPolicy()
        let event = MemberMemoryEvent(
            eventID: "exercise:session-1",
            interactionID: "session-1",
            kind: .exerciseDisclosure,
            source: .memberReported,
            recordedAt: date("2026-09-18T09:00:00+08:00"),
            exerciseDisclosure: .completedToday
        )

        let sameDay = policy.snapshot(
            from: [event],
            at: date("2026-09-18T12:00:00+08:00"),
            timeZone: timeZone
        )
        let nextDay = policy.snapshot(
            from: [event],
            at: date("2026-09-19T00:01:00+08:00"),
            timeZone: timeZone
        )

        #expect(sameDay.currentExerciseDisclosure == .completedToday)
        #expect(sameDay.currentExerciseDisclosureRecordedAt == event.recordedAt)
        #expect(nextDay.currentExerciseDisclosure == nil)
        #expect(nextDay.currentExerciseDisclosureRecordedAt == nil)
    }

    @Test("validates disclosure lifetime and fails closed for clock rollback")
    func validatesExerciseDisclosureLifetime() {
        let recordedAt = date("2026-09-18T23:59:00+08:00")
        let sameDay = date("2026-09-18T23:59:30+08:00")
        let nextDay = date("2026-09-19T00:01:00+08:00")
        let beforeReport = date("2026-09-18T23:58:00+08:00")

        #expect(MemberInteractionMemoryPolicy.isExerciseDisclosureActive(
            .completedToday,
            recordedAt: recordedAt,
            at: sameDay
        ))
        #expect(!MemberInteractionMemoryPolicy.isExerciseDisclosureActive(
            .completedToday,
            recordedAt: recordedAt,
            at: nextDay
        ))
        #expect(!MemberInteractionMemoryPolicy.isExerciseDisclosureActive(
            .completedToday,
            recordedAt: recordedAt,
            at: beforeReport
        ))
        #expect(!MemberInteractionMemoryPolicy.isExerciseDisclosureActive(
            .completedToday,
            recordedAt: nil,
            at: sameDay
        ))
        #expect(MemberInteractionMemoryPolicy.isExerciseDisclosureActive(
            .preparing,
            recordedAt: nil,
            at: nextDay
        ))
        #expect(MemberInteractionMemoryPolicy.isExerciseDisclosureActive(
            .justCompleted,
            recordedAt: nil,
            at: nextDay
        ))
    }

    private func meeting(_ id: String, _ value: String) -> MemberMemoryEvent {
        MemberMemoryEvent(
            eventID: id,
            interactionID: id,
            kind: .meeting,
            source: .lumiObserved,
            recordedAt: date(value),
            exerciseDisclosure: nil
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        return formatter.date(from: value)!
    }
}
