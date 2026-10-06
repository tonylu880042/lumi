import Foundation
import LumiApplication
import LumiDomain
import Testing

@Suite("Member departure voice context")
struct MemberDepartureEncouragementTests {
    private let first = Date(timeIntervalSince1970: 1_790_902_800) // 2026-10-02 09:00 Taipei

    @Test("only eligible later encounters disclose the observed calendar-week count")
    func mapsEligibleSnapshot() {
        let event = MemberMemoryEvent(
            eventID: "first", interactionID: "first", kind: .meeting,
            source: .lumiObserved, recordedAt: first, exerciseDisclosure: nil
        )
        let policy = MemberInteractionMemoryPolicy()
        let early = VoiceMemberMemoryContext(snapshot: policy.snapshot(
            from: [event], at: first.addingTimeInterval(1799)
        ))
        let later = VoiceMemberMemoryContext(snapshot: policy.snapshot(
            from: [event], at: first.addingTimeInterval(1800)
        ))
        #expect(early.departureWeeklyMeetingDayCount == nil)
        #expect(later.departureWeeklyMeetingDayCount == 1)
    }

    @Test("departure count expires at the Taipei date boundary and on clock rollback")
    func expiresDepartureContext() {
        let context = VoiceMemberMemoryContext(
            highlight: .seenToday, departureWeeklyMeetingDayCount: 3,
            departureFirstMeetingAt: first
        )
        #expect(context.effective(at: first.addingTimeInterval(1800))
            .departureWeeklyMeetingDayCount == 3)
        #expect(context.effective(at: first.addingTimeInterval(1799))
            .departureWeeklyMeetingDayCount == nil)
        #expect(context.effective(at: first.addingTimeInterval(86400))
            .departureWeeklyMeetingDayCount == nil)
    }

    @Test("exercise updates and expiry preserve valid departure context")
    func exerciseChangesPreserveDeparture() {
        let context = VoiceMemberMemoryContext(
            highlight: .seenToday, departureWeeklyMeetingDayCount: 3,
            departureFirstMeetingAt: first
        )
        let updated = context.updatingExerciseDisclosure(.completedToday, recordedAt: nil)
        let effective = updated.effective(at: first.addingTimeInterval(1800))
        #expect(effective.currentExerciseDisclosure == nil)
        #expect(effective.departureWeeklyMeetingDayCount == 3)
    }
}
