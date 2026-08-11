import Foundation
import LumiApplication
import LumiDomain
import Testing

@Suite("Member repository contract")
struct MemberRepositoryContractTests {
    @Test("profile routes the exact member ID and returns the configured member")
    func profileRoutesExactIDAndReturnsConfiguredMember() async throws {
        let memberID = try MemberID(rawValue: "  M-001/exact  ")
        let expected = Member(id: memberID, displayName: "王小姐")
        let repository = TestMemberRepository(
            profile: expected,
            weeklySummary: ExerciseSummary(
                visitsThisWeek: 2,
                activityMETMinutes: 580.5,
                lastWorkoutAt: Date(timeIntervalSince1970: 1_754_464_200),
                todayCompleted: false
            )
        )
        let port: any MemberRepository = repository
        acceptsSendable(port)

        let actual = try await port.profile(for: memberID)

        #expect(actual == expected)
        #expect(await repository.profileRequests == [memberID])
    }

    @Test("weekly summary routes the exact member ID and returns the configured summary")
    func weeklySummaryRoutesExactIDAndReturnsConfiguredSummary() async throws {
        let memberID = try MemberID(rawValue: "M-002")
        let expected = ExerciseSummary(
            visitsThisWeek: 4,
            activityMETMinutes: nil,
            lastWorkoutAt: nil,
            todayCompleted: true
        )
        let repository = TestMemberRepository(
            profile: Member(id: memberID, displayName: "李小姐"),
            weeklySummary: expected
        )
        let port: any MemberRepository = repository
        acceptsSendable(port)

        let actual = try await port.weeklySummary(for: memberID)

        #expect(actual == expected)
        #expect(await repository.weeklySummaryRequests == [memberID])
    }
}

private actor TestMemberRepository: MemberRepository {
    private let configuredProfile: Member
    private let configuredWeeklySummary: ExerciseSummary

    private(set) var profileRequests: [MemberID] = []
    private(set) var weeklySummaryRequests: [MemberID] = []

    init(profile: Member, weeklySummary: ExerciseSummary) {
        self.configuredProfile = profile
        self.configuredWeeklySummary = weeklySummary
    }

    func profile(for id: MemberID) async throws -> Member {
        profileRequests.append(id)
        return configuredProfile
    }

    func weeklySummary(for id: MemberID) async throws -> ExerciseSummary {
        weeklySummaryRequests.append(id)
        return configuredWeeklySummary
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
