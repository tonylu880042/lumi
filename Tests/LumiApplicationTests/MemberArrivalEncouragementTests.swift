import Foundation
import LumiApplication
import LumiDomain
import Testing

@Suite("Member arrival voice context")
struct MemberArrivalEncouragementTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-06T09:00:00+08:00")!

    @Test("first arrival maps the current ordinal and remains a personalized opener")
    func mapsArrivalOrdinal() {
        let snapshot = MemberInteractionMemoryPolicy().snapshot(from: [], at: now)
        let context = VoiceMemberMemoryContext(snapshot: snapshot, encounterAt: now)
        #expect(context.arrivalWeeklyMeetingDayCount == 1)
        #expect(context.departureWeeklyMeetingDayCount == nil)
        #expect(context.hasPersonalizedOpening)
        #expect(context.effective(at: now).arrivalWeeklyMeetingDayCount == 1)
    }

    @Test("arrival context cannot survive Taipei midnight or clock rollback")
    func expiresArrivalContext() {
        let context = VoiceMemberMemoryContext(
            highlight: nil, arrivalWeeklyMeetingDayCount: 2, arrivalEncounterAt: now
        )
        #expect(context.effective(at: now.addingTimeInterval(1))
            .arrivalWeeklyMeetingDayCount == 2)
        #expect(context.effective(at: now.addingTimeInterval(-1))
            .arrivalWeeklyMeetingDayCount == nil)
        #expect(context.effective(at: now.addingTimeInterval(86400))
            .arrivalWeeklyMeetingDayCount == nil)
        #expect(context.effective(at: Date(timeIntervalSince1970: .nan))
            .arrivalWeeklyMeetingDayCount == nil)
    }

    @Test("exercise context updates preserve the valid arrival ordinal")
    func disclosureUpdatesPreserveArrival() {
        let context = VoiceMemberMemoryContext(
            highlight: .longAbsent, arrivalWeeklyMeetingDayCount: 1,
            arrivalEncounterAt: now
        ).updatingExerciseDisclosure(.preparing, recordedAt: nil)
        #expect(context.effective(at: now).arrivalWeeklyMeetingDayCount == 1)
        #expect(context.effective(at: now).currentExerciseDisclosure == .preparing)
    }
}
