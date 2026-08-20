#if DEBUG
import Foundation
import LumiApplication
import LumiDomain
import LumiInfrastructure
import Testing
@testable import LumiApp

@Suite("Debug-Live member fixture")
struct DebugMemberFixtureTests {
    @Test("fixture contains exactly the synthetic known member and fixed data")
    func fixtureContainsExactSyntheticRecord() throws {
        #expect(DebugMemberFixture.records.count == 1)
        let record = try #require(DebugMemberFixture.records.first)

        #expect(record.member.id == SessionSimulationModel.debugKnownMemberID)
        #expect(record.member.displayName == "Lumi 開發測試會員")
        #expect(record.weeklySummary.visitsThisWeek == 2)
        #expect(record.weeklySummary.activityMETMinutes == 580.5)
        #expect(
            record.weeklySummary.lastWorkoutAt
                == Date(timeIntervalSince1970: 1_787_020_200)
        )
        #expect(record.weeklySummary.todayCompleted == false)
        #expect(DebugMemberFixture.promptAddition.contains("Debug-Live"))
        #expect(DebugMemberFixture.promptAddition.contains("開發測試資料"))
        #expect(DebugMemberFixture.promptAddition.contains("Curves 真實會員紀錄"))
        #expect(DebugMemberFixture.promptAddition.contains("以下是開發測試資料"))
    }

    @Test("fixture repository returns the exact provider-neutral summary JSON")
    func fixtureRepositoryReturnsExactSummaryJSON() async throws {
        let repository = try DebugMemberFixture.makeRepository()
        let summary = try await GetMemberWeeklySummaryUseCase(
            repository: repository
        ).execute(for: SessionSimulationModel.debugKnownMemberID)

        #expect(
            String(data: summary.jsonData(), encoding: .utf8)
                == #"{"activity_met_minutes":580.5,"last_workout_at":"2026-08-18T02:30:00.000Z","today_completed":false,"visits_this_week":2}"#
        )
    }
}
#endif
