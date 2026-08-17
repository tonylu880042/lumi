import Foundation
import LumiDomain

/// Versioned record envelope for a CloudKit private-database backup.
///
/// The payload is opaque here: the identity subsystem owns its serialization
/// and any future managed-at-rest protection policy. No face embedding or
/// member display name is logged by this adapter.
struct CloudKitBackupRecord: Equatable, Sendable {
    let recordName: String
    let schemaVersion: Int
    let payload: Data
}

enum CloudKitPrivateDatabaseClientError: Error, Equatable, Sendable {
    case injected
    case unavailable
}

/// Injectable boundary around the CloudKit private database.
protocol CloudKitPrivateDatabaseClient: Sendable {
    func save(_ record: CloudKitBackupRecord) async throws
    func load(recordName: String) async throws -> CloudKitBackupRecord?
    func delete(recordName: String) async throws
}

enum CloudKitMemberDataBackupError: Error, Equatable, Sendable {
    case databaseFailure
}

/// Application-neutral backup coordinator for a member's local data envelope.
///
/// The production CloudKit client will use the user's private database, which
/// follows the Apple ID signed into the device. This slice deliberately keeps
/// the native CloudKit SDK behind the injectable client seam so tests remain
/// offline and no store-side key workflow is introduced.
struct CloudKitMemberDataBackup: Sendable {
    private let client: any CloudKitPrivateDatabaseClient

    init(client: any CloudKitPrivateDatabaseClient) {
        self.client = client
    }

    func save(_ payload: Data, for memberID: MemberID) async throws {
        try Task.checkCancellation()
        do {
            try await client.save(CloudKitBackupRecord(
                recordName: Self.recordName(for: memberID),
                schemaVersion: 1,
                payload: payload
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudKitMemberDataBackupError.databaseFailure
        }
    }

    func load(for memberID: MemberID) async throws -> Data? {
        try Task.checkCancellation()
        do {
            return try await client.load(recordName: Self.recordName(for: memberID))?.payload
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudKitMemberDataBackupError.databaseFailure
        }
    }

    func remove(for memberID: MemberID) async throws {
        try Task.checkCancellation()
        do {
            try await client.delete(recordName: Self.recordName(for: memberID))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudKitMemberDataBackupError.databaseFailure
        }
    }

    private static func recordName(for memberID: MemberID) -> String {
        "member-\(memberID.rawValue)"
    }
}
