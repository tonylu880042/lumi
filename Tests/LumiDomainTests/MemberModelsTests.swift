import Foundation
import LumiDomain
import Testing

@Test("member exposes its ID and display name")
func memberExposesIDAndDisplayName() throws {
    let memberID = try MemberID(rawValue: "member-001")
    let member = Member(id: memberID, displayName: "王小姐")

    #expect(member.id == memberID)
    #expect(member.displayName == "王小姐")
}

@Test("exercise summary preserves non-nil optional values")
func exerciseSummaryPreservesNonNilOptionals() {
    let lastWorkoutAt = Date(timeIntervalSince1970: 1_754_464_200)
    let summary = ExerciseSummary(
        visitsThisWeek: 2,
        activityMETMinutes: 580.5,
        lastWorkoutAt: lastWorkoutAt,
        todayCompleted: false
    )

    #expect(summary.visitsThisWeek == 2)
    #expect(summary.activityMETMinutes == 580.5)
    #expect(summary.lastWorkoutAt == lastWorkoutAt)
    #expect(summary.todayCompleted == false)
}

@Test("exercise summary preserves nil optional values")
func exerciseSummaryPreservesNilOptionals() {
    let summary = ExerciseSummary(
        visitsThisWeek: 0,
        activityMETMinutes: nil,
        lastWorkoutAt: nil,
        todayCompleted: false
    )

    #expect(summary.activityMETMinutes == nil)
    #expect(summary.lastWorkoutAt == nil)
}

@Test("member and exercise summary are equatable")
func memberModelsAreEquatable() throws {
    let memberID = try MemberID(rawValue: "member-001")
    let member = Member(id: memberID, displayName: "王小姐")
    #expect(member == Member(id: memberID, displayName: "王小姐"))
    #expect(member != Member(id: memberID, displayName: "李小姐"))

    let summary = ExerciseSummary(
        visitsThisWeek: 2,
        activityMETMinutes: 580.5,
        lastWorkoutAt: Date(timeIntervalSince1970: 1_754_464_200),
        todayCompleted: false
    )
    #expect(summary == ExerciseSummary(
        visitsThisWeek: 2,
        activityMETMinutes: 580.5,
        lastWorkoutAt: Date(timeIntervalSince1970: 1_754_464_200),
        todayCompleted: false
    ))
    #expect(summary != ExerciseSummary(
        visitsThisWeek: 3,
        activityMETMinutes: 580.5,
        lastWorkoutAt: Date(timeIntervalSince1970: 1_754_464_200),
        todayCompleted: false
    ))
}

@Test("member models are sendable")
func memberModelsAreSendable() throws {
    let memberID = try MemberID(rawValue: "member-001")
    acceptsSendable(Member(id: memberID, displayName: "王小姐"))
    acceptsSendable(ExerciseSummary(
        visitsThisWeek: 2,
        activityMETMinutes: nil,
        lastWorkoutAt: nil,
        todayCompleted: false
    ))
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
