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
        "你目前正在 Debug-Live 開發測試。工具回傳的是開發測試資料，不是 Curves 真實會員紀錄；回答時必須先明確說「以下是開發測試資料」。"

    static func makeRepository() throws -> MockMemberRepository {
        try MockMemberRepository(records: records)
    }
}
#endif
