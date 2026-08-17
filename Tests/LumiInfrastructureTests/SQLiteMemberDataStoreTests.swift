import Foundation
import LumiDomain
import LumiApplication
import LumiInfrastructure
import Testing

@Suite("SQLite member data store")
struct SQLiteMemberDataStoreTests {
    @Test("saves and loads the exact member profile")
    func savesAndLoadsProfile() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMemberDataStore(databaseURL: databaseURL)
        let memberID = try MemberID(rawValue: "member-001")
        let member = Member(id: memberID, displayName: "王小姐")

        try await store.saveMember(member)

        #expect(try await store.member(for: memberID) == member)
    }

    @Test("records visits and derives the approved frequency band")
    func recordsVisitsAndDerivesFrequency() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMemberDataStore(databaseURL: databaseURL)
        let memberID = try MemberID(rawValue: "member-001")
        let weekStart = Date(timeIntervalSince1970: 1_754_400_000)
        let arrivals = [
            weekStart.addingTimeInterval(60),
            weekStart.addingTimeInterval(120),
            weekStart.addingTimeInterval(180)
        ]

        for arrival in arrivals {
            try await store.recordVisit(memberID: memberID, at: arrival)
        }

        let summary = try await store.visitSummary(for: memberID, since: weekStart)
        #expect(summary.visitCount == 3)
        #expect(summary.lastArrivalAt == arrivals.last)
        #expect(summary.frequencyBand == .threeOrMore)
    }

    @Test("reopening the same database preserves profiles and visits")
    func reopensPersistedDatabase() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let memberID = try MemberID(rawValue: "member-001")
        let member = Member(id: memberID, displayName: "王小姐")
        let arrival = Date(timeIntervalSince1970: 1_754_464_200)

        do {
            let store = try SQLiteMemberDataStore(databaseURL: databaseURL)
            try await store.saveMember(member)
            try await store.recordVisit(memberID: memberID, at: arrival)
        }

        let reopened = try SQLiteMemberDataStore(databaseURL: databaseURL)
        #expect(try await reopened.member(for: memberID) == member)
        let summary = try await reopened.visitSummary(for: memberID, since: arrival.addingTimeInterval(-1))
        #expect(summary.visitCount == 1)
        #expect(summary.lastArrivalAt == arrival)
    }

    private func temporaryDatabaseURL() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-member-data-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }
}
