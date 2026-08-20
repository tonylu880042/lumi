import Foundation
import LumiApplication
import LumiDomain
import LumiInfrastructure
import Testing

@Suite("Mock member repository")
struct MockMemberRepositoryTests {
    @Test("returns exact profiles and weekly summaries independent of record order")
    func returnsExactValuesIndependentOfRecordOrder() async throws {
        let firstID = try MemberID(rawValue: "mock-member-first")
        let secondID = try MemberID(rawValue: "mock-member-second")
        let first = MockMemberRecord(
            member: Member(id: firstID, displayName: "First test member"),
            weeklySummary: ExerciseSummary(
                visitsThisWeek: 2,
                activityMETMinutes: 120.5,
                lastWorkoutAt: Date(timeIntervalSince1970: 1_800_000_000),
                todayCompleted: false
            )
        )
        let second = MockMemberRecord(
            member: Member(id: secondID, displayName: "Second test member"),
            weeklySummary: ExerciseSummary(
                visitsThisWeek: 5,
                activityMETMinutes: nil,
                lastWorkoutAt: nil,
                todayCompleted: true
            )
        )

        let repository = try MockMemberRepository(records: [second, first])
        let reorderedRepository = try MockMemberRepository(records: [first, second])

        #expect(try await repository.profile(for: firstID) == first.member)
        #expect(
            try await repository.weeklySummary(for: firstID)
                == first.weeklySummary
        )
        #expect(try await repository.profile(for: secondID) == second.member)
        #expect(
            try await repository.weeklySummary(for: secondID)
                == second.weeklySummary
        )
        #expect(
            try await reorderedRepository.profile(for: firstID)
                == first.member
        )
        #expect(
            try await reorderedRepository.weeklySummary(for: firstID)
                == first.weeklySummary
        )
        #expect(
            try await reorderedRepository.profile(for: secondID)
                == second.member
        )
        #expect(
            try await reorderedRepository.weeklySummary(for: secondID)
                == second.weeklySummary
        )
    }

    @Test("unknown profiles and summaries return one redacted fixed error")
    func unknownLookupsAreRedactedAndDeterministic() async throws {
        let knownID = try MemberID(rawValue: "known-member")
        let unknownID = try MemberID(rawValue: "member-secret-marker")
        let repository = try MockMemberRepository(
            records: [
                MockMemberRecord(
                    member: Member(id: knownID, displayName: "Known test member"),
                    weeklySummary: ExerciseSummary(
                        visitsThisWeek: 1,
                        activityMETMinutes: nil,
                        lastWorkoutAt: nil,
                        todayCompleted: false
                    )
                )
            ]
        )

        do {
            _ = try await repository.profile(for: unknownID)
            Issue.record("Expected an unknown profile lookup to fail")
        } catch let error as MockMemberRepositoryError {
            #expect(error == .memberNotFound)
            assertRedacted(error, from: unknownID)
        }

        do {
            _ = try await repository.weeklySummary(for: unknownID)
            Issue.record("Expected an unknown summary lookup to fail")
        } catch let error as MockMemberRepositoryError {
            #expect(error == .memberNotFound)
            assertRedacted(error, from: unknownID)
        }
    }

    @Test("an empty repository has no implicit sample records")
    func emptyRepositoryHasNoImplicitSamples() async throws {
        let repository = try MockMemberRepository(records: [])
        let unknownID = try MemberID(rawValue: "any-member")

        await #expect(throws: MockMemberRepositoryError.memberNotFound) {
            _ = try await repository.profile(for: unknownID)
        }
        await #expect(throws: MockMemberRepositoryError.memberNotFound) {
            _ = try await repository.weeklySummary(for: unknownID)
        }
    }

    @Test("duplicate member IDs are rejected without exposing the ID")
    func duplicateMemberIDsAreRejectedAndRedacted() throws {
        let duplicateID = try MemberID(rawValue: "duplicate-member-secret")
        let first = MockMemberRecord(
            member: Member(id: duplicateID, displayName: "First"),
            weeklySummary: ExerciseSummary(
                visitsThisWeek: 1,
                activityMETMinutes: nil,
                lastWorkoutAt: nil,
                todayCompleted: false
            )
        )
        let second = MockMemberRecord(
            member: Member(id: duplicateID, displayName: "Second"),
            weeklySummary: ExerciseSummary(
                visitsThisWeek: 2,
                activityMETMinutes: 20,
                lastWorkoutAt: nil,
                todayCompleted: true
            )
        )

        do {
            _ = try MockMemberRepository(records: [first, second])
            Issue.record("Expected duplicate member IDs to be rejected")
        } catch {
            #expect(error == .duplicateMember)
            assertRedacted(error, from: duplicateID)
        }
    }

    @Test("repository records and errors are Sendable")
    func valuesAreSendable() throws {
        let memberID = try MemberID(rawValue: "sendable-member")
        let record = MockMemberRecord(
            member: Member(id: memberID, displayName: "Sendable test member"),
            weeklySummary: ExerciseSummary(
                visitsThisWeek: 0,
                activityMETMinutes: nil,
                lastWorkoutAt: nil,
                todayCompleted: false
            )
        )
        let repository = try MockMemberRepository(records: [record])

        acceptsSendable(record)
        acceptsSendable(repository)
        acceptsSendable(MockMemberRepositoryError.memberNotFound)
        acceptsSendable(MockMemberRepositoryError.duplicateMember)
    }

    private func assertRedacted(
        _ error: MockMemberRepositoryError,
        from memberID: MemberID
    ) {
        #expect(error.description == error.debugDescription)
        #expect(Mirror(reflecting: error).children.isEmpty)
        #expect(!String(describing: error).contains(memberID.rawValue))
        #expect(!String(reflecting: error).contains(memberID.rawValue))
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
