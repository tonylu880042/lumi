import Foundation
import LumiDomain
@testable import LumiInfrastructure
import Testing

@Suite("CloudKit member data backup")
struct CloudKitMemberDataBackupTests {
    @Test("saves and loads the exact versioned payload through the private database seam")
    func savesAndLoadsExactPayload() async throws {
        let client = RecordingCloudKitDatabaseClient()
        let backup = CloudKitMemberDataBackup(client: client)
        let memberID = try MemberID(rawValue: "member-001")
        let payload = Data([0, 127, 255])

        try await backup.save(payload, for: memberID)

        #expect(await client.savedRecords.count == 1)
        #expect(try await backup.load(for: memberID) == payload)
        let saved = await client.savedRecords[0]
        #expect(saved.recordName == "member-member-001")
        #expect(saved.schemaVersion == 1)
        #expect(saved.payload == payload)
    }

    @Test("missing records load as nil and removal is forwarded")
    func missingAndRemovalAreSafe() async throws {
        let client = RecordingCloudKitDatabaseClient()
        let backup = CloudKitMemberDataBackup(client: client)
        let memberID = try MemberID(rawValue: "member-001")

        #expect(try await backup.load(for: memberID) == nil)
        try await backup.remove(for: memberID)
        #expect(await client.deletedRecordNames == ["member-member-001"])
    }

    @Test("database failures map to a fixed privacy-safe error")
    func mapsDatabaseFailure() async throws {
        let client = RecordingCloudKitDatabaseClient()
        await client.setFailure(.injected)
        let backup = CloudKitMemberDataBackup(client: client)
        let memberID = try MemberID(rawValue: "member-001")

        await #expect(throws: CloudKitMemberDataBackupError.databaseFailure) {
            try await backup.save(Data([1]), for: memberID)
        }
    }
}

private actor RecordingCloudKitDatabaseClient: CloudKitPrivateDatabaseClient {
    private(set) var savedRecords: [CloudKitBackupRecord] = []
    private(set) var deletedRecordNames: [String] = []
    private var records: [String: CloudKitBackupRecord] = [:]
    private var failure: CloudKitPrivateDatabaseClientError?

    func save(_ record: CloudKitBackupRecord) throws {
        if let failure { throw failure }
        savedRecords.append(record)
        records[record.recordName] = record
    }

    func load(recordName: String) throws -> CloudKitBackupRecord? {
        if let failure { throw failure }
        return records[recordName]
    }

    func delete(recordName: String) throws {
        if let failure { throw failure }
        deletedRecordNames.append(recordName)
        records.removeValue(forKey: recordName)
    }

    func setFailure(_ failure: CloudKitPrivateDatabaseClientError?) {
        self.failure = failure
    }
}
