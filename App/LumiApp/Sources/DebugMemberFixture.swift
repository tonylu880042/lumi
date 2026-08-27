#if DEBUG
import Foundation
import LumiDomain
import LumiInfrastructure

/// Fixed synthetic member data used only by the Debug-Live composition.
enum DebugMemberFixture {
    static let records: [MockMemberRecord] = [
        MockMemberRecord(
            member: Member(
                id: SessionSimulationModel.debugKnownMemberID,
                displayName: "Lumi 開發測試會員"
            ),
            weeklySummary: ExerciseSummary(
                visitsThisWeek: 2,
                activityMETMinutes: 580.5,
                lastWorkoutAt: Date(timeIntervalSince1970: 1_787_020_200),
                todayCompleted: false
            )
        )
    ]

    static let promptAddition =
        OpenAIConversationPrompts.debugFixtureDisclosure

    static func makeRepository() throws -> MockMemberRepository {
        try MockMemberRepository(records: records)
    }
}
#endif
