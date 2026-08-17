import Foundation
import LumiApplication
import LumiDomain

#if canImport(SQLite3)
import SQLite3

/// Errors intentionally contain no database path, SQL, member ID, or raw data.
public enum SQLiteMemberDataStoreError: Error, Equatable, Sendable {
    case invalidDatabase
    case statementPreparationFailed
    case operationFailed
    case invalidStoredMember
}

/// Local-first SQLite store for member profiles and visit events.
///
/// The actor owns the SQLite connection, so callers never share a raw
/// SQLite handle across concurrency domains. The database file can later be
/// protected with the platform's Data Protection attributes by the composition
/// root without changing this Application-facing contract.
public actor SQLiteMemberDataStore: LocalMemberDataStore {
    private let connection: SQLiteConnection

    public init(databaseURL: URL) throws(SQLiteMemberDataStoreError) {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw .invalidDatabase
        }

        do {
            try Self.createSchema(handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        connection = SQLiteConnection(handle)
    }

    public func saveMember(_ member: Member) throws(SQLiteMemberDataStoreError) {
        let sql = "INSERT INTO members (member_id, display_name) VALUES (?, ?) "
            + "ON CONFLICT(member_id) DO UPDATE SET display_name = excluded.display_name;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(member.id.rawValue, at: 1, in: statement)
        try bind(member.displayName, at: 2, in: statement)
        try step(statement, expecting: SQLITE_DONE)
    }

    public func member(for id: MemberID) throws(SQLiteMemberDataStoreError) -> Member? {
        let statement = try prepare("SELECT display_name FROM members WHERE member_id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bind(id.rawValue, at: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let displayName: String?
            if let namePointer = sqlite3_column_text(statement, 0) {
                displayName = namePointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(validatingCString: $0)
                }
            } else {
                displayName = nil
            }
            guard let displayName else { throw .invalidStoredMember }
            return Member(id: id, displayName: displayName)
        case SQLITE_DONE:
            return nil
        default:
            throw .operationFailed
        }
    }

    public func recordVisit(memberID: MemberID, at arrival: Date) throws(SQLiteMemberDataStoreError) {
        let statement = try prepare("INSERT INTO visits (member_id, arrived_at) VALUES (?, ?);")
        defer { sqlite3_finalize(statement) }
        try bind(memberID.rawValue, at: 1, in: statement)
        guard sqlite3_bind_double(statement, 2, arrival.timeIntervalSince1970) == SQLITE_OK else {
            throw .operationFailed
        }
        try step(statement, expecting: SQLITE_DONE)
    }

    public func visitSummary(
        for memberID: MemberID,
        since startDate: Date
    ) throws(SQLiteMemberDataStoreError) -> MemberVisitSummary {
        let statement = try prepare(
            "SELECT COUNT(*), MAX(arrived_at) FROM visits WHERE member_id = ? AND arrived_at >= ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(memberID.rawValue, at: 1, in: statement)
        guard sqlite3_bind_double(statement, 2, startDate.timeIntervalSince1970) == SQLITE_OK else {
            throw .operationFailed
        }

        guard sqlite3_step(statement) == SQLITE_ROW else { throw .operationFailed }
        let count = Int(sqlite3_column_int64(statement, 0))
        let lastArrival: Date?
        if sqlite3_column_type(statement, 1) == SQLITE_NULL {
            lastArrival = nil
        } else {
            lastArrival = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        }
        return MemberVisitSummary(visitCount: count, lastArrivalAt: lastArrival)
    }

    private func prepare(_ sql: String) throws(SQLiteMemberDataStoreError) -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.pointer, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw .statementPreparationFailed }
        return statement
    }

    private func bind(
        _ value: String,
        at index: Int32,
        in statement: OpaquePointer
    ) throws(SQLiteMemberDataStoreError) {
        let result = value.withCString { pointer in
            sqlite3_bind_text(
                statement,
                index,
                pointer,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard result == SQLITE_OK else { throw .operationFailed }
    }

    private func step(
        _ statement: OpaquePointer,
        expecting expectedResult: Int32
    ) throws(SQLiteMemberDataStoreError) {
        guard sqlite3_step(statement) == expectedResult else { throw .operationFailed }
    }

    private static func createSchema(_ database: OpaquePointer) throws(SQLiteMemberDataStoreError) {
        let sql = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS members (
            member_id TEXT PRIMARY KEY NOT NULL,
            display_name TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS visits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            member_id TEXT NOT NULL,
            arrived_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS visits_member_arrival
            ON visits(member_id, arrived_at);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw .operationFailed
        }
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}
#endif
