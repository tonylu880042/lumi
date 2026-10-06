import Foundation
import LumiApplication
import LumiDomain

#if canImport(SQLite3)
import SQLite3

/// Errors intentionally contain no database path, SQL, member ID, or raw data.
public enum SQLiteMemberInteractionMemoryStoreError: Error, Equatable, Sendable {
    case invalidDatabase
    case statementPreparationFailed
    case operationFailed
    case invalidStoredMemory
    case invalidMemoryEvent
    case invalidMemoryDate
    case memoryDisabled
}

/// Independent SQLite persistence for consented interaction memory.
///
/// This adapter owns a database that contains only memory consent and
/// structured memory events. Member profiles, display names, visits, and face
/// embeddings stay in their respective stores and are never joined here.
public actor SQLiteMemberInteractionMemoryStore: MemberInteractionMemoryStore {
    private let connection: MemorySQLiteConnection

    public init(databaseURL: URL) throws(SQLiteMemberInteractionMemoryStoreError) {
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
        connection = MemorySQLiteConnection(handle)
    }

    public func consentStatus(
        for memberID: MemberID
    ) async throws -> MemberMemoryConsentStatus {
        guard let state = try memoryConsentState(for: memberID) else {
            return .disabled
        }
        return try consentStatus(from: state)
    }

    public func loadBatch(
        for memberID: MemberID,
        at now: Date
    ) async throws -> MemberMemoryEventBatch {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw SQLiteMemberInteractionMemoryStoreError.invalidMemoryDate
        }
        guard let state = try memoryConsentState(for: memberID), state.enabled else {
            throw SQLiteMemberInteractionMemoryStoreError.memoryDisabled
        }

        try pruneExpiredMemory(for: memberID, at: now)

        guard let currentState = try memoryConsentState(for: memberID), currentState.enabled else {
            throw SQLiteMemberInteractionMemoryStoreError.memoryDisabled
        }
        let statement = try prepare(
            "SELECT event_id, interaction_id, kind, source, recorded_at, "
                + "exercise_disclosure FROM member_memory_events "
                + "WHERE member_id = ? ORDER BY recorded_at ASC, id ASC;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(memberID.rawValue, at: 1, in: statement)

        var events: [MemberMemoryEvent] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                events.append(try decodeMemoryEvent(from: statement))
            case SQLITE_DONE:
                return MemberMemoryEventBatch(
                    events: events,
                    revision: currentState.revision
                )
            default:
                throw SQLiteMemberInteractionMemoryStoreError.operationFailed
            }
        }
    }

    public func append(
        _ event: MemberMemoryEvent,
        for memberID: MemberID,
        expectedRevision: UInt64
    ) async throws -> MemberMemoryAppendResult {
        try validateMemoryEvent(event)
        try execute("BEGIN IMMEDIATE;")
        do {
            guard let state = try memoryConsentState(for: memberID) else {
                try execute("ROLLBACK;")
                return MemberMemoryAppendResult(outcome: .rejected, revision: 0)
            }
            guard state.enabled else {
                try execute("ROLLBACK;")
                return MemberMemoryAppendResult(
                    outcome: .rejected,
                    revision: state.revision
                )
            }
            guard state.revision == expectedRevision else {
                try execute("ROLLBACK;")
                return MemberMemoryAppendResult(
                    outcome: .rejected,
                    revision: state.revision
                )
            }

            let statement = try prepare(
                "INSERT OR IGNORE INTO member_memory_events "
                    + "(member_id, event_id, interaction_id, kind, source, recorded_at, exercise_disclosure) "
                    + "VALUES (?, ?, ?, ?, ?, ?, ?);"
            )
            defer { sqlite3_finalize(statement) }
            try bind(memberID.rawValue, at: 1, in: statement)
            try bind(event.eventID, at: 2, in: statement)
            try bind(event.interactionID, at: 3, in: statement)
            try bind(memoryKindWireValue(event.kind), at: 4, in: statement)
            try bind(memorySourceWireValue(event.source), at: 5, in: statement)
            try bind(event.recordedAt.timeIntervalSince1970, at: 6, in: statement)
            if let disclosure = event.exerciseDisclosure {
                try bind(memoryDisclosureWireValue(disclosure), at: 7, in: statement)
            } else {
                guard sqlite3_bind_null(statement, 7) == SQLITE_OK else {
                    throw SQLiteMemberInteractionMemoryStoreError.operationFailed
                }
            }
            try step(statement, expecting: SQLITE_DONE)

            guard sqlite3_changes(connection.pointer) > 0 else {
                try execute("COMMIT;")
                return MemberMemoryAppendResult(
                    outcome: .duplicate,
                    revision: state.revision
                )
            }
            try incrementMemoryRevision(for: memberID)
            try execute("COMMIT;")
            return MemberMemoryAppendResult(
                outcome: .appended,
                revision: state.revision &+ 1
            )
        } catch let error as SQLiteMemberInteractionMemoryStoreError {
            try? execute("ROLLBACK;")
            throw error
        } catch {
            try? execute("ROLLBACK;")
            throw SQLiteMemberInteractionMemoryStoreError.operationFailed
        }
    }

    public func correctExerciseDisclosure(
        for memberID: MemberID,
        at now: Date,
        expectedRevision: UInt64
    ) async throws -> MemberMemoryCorrectionResult {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw SQLiteMemberInteractionMemoryStoreError.invalidMemoryDate
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MemberInteractionMemoryPolicy.storeTimeZone
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw SQLiteMemberInteractionMemoryStoreError.invalidMemoryDate
        }

        try execute("BEGIN IMMEDIATE;")
        do {
            guard let state = try memoryConsentState(for: memberID), state.enabled else {
                try execute("ROLLBACK;")
                return MemberMemoryCorrectionResult(
                    outcome: .rejected,
                    revision: 0
                )
            }
            guard state.revision == expectedRevision else {
                try execute("ROLLBACK;")
                return MemberMemoryCorrectionResult(
                    outcome: .rejected,
                    revision: state.revision
                )
            }

            let delete = try prepare(
                "DELETE FROM member_memory_events WHERE member_id = ? "
                    + "AND kind = 'exerciseDisclosure' "
                    + "AND exercise_disclosure = 'completedToday' "
                    + "AND recorded_at >= ? AND recorded_at < ?;"
            )
            defer { sqlite3_finalize(delete) }
            try bind(memberID.rawValue, at: 1, in: delete)
            try bind(start.timeIntervalSince1970, at: 2, in: delete)
            try bind(end.timeIntervalSince1970, at: 3, in: delete)
            try step(delete, expecting: SQLITE_DONE)

            guard sqlite3_changes(connection.pointer) > 0 else {
                try execute("COMMIT;")
                return MemberMemoryCorrectionResult(
                    outcome: .notFound,
                    revision: state.revision
                )
            }
            try incrementMemoryRevision(for: memberID)
            try execute("COMMIT;")
            return MemberMemoryCorrectionResult(
                outcome: .corrected,
                revision: state.revision &+ 1
            )
        } catch let error as SQLiteMemberInteractionMemoryStoreError {
            try? execute("ROLLBACK;")
            throw error
        } catch {
            try? execute("ROLLBACK;")
            throw SQLiteMemberInteractionMemoryStoreError.operationFailed
        }
    }

    public func setConsent(
        for memberID: MemberID,
        status: MemberMemoryConsentStatus
    ) async throws {
        let consentedAt: Date?
        let enabled: Int32
        switch status {
        case .disabled:
            consentedAt = nil
            enabled = 0
        case let .enabled(date):
            guard date.timeIntervalSinceReferenceDate.isFinite else {
                throw SQLiteMemberInteractionMemoryStoreError.invalidMemoryDate
            }
            consentedAt = date
            enabled = 1
        }

        try execute("BEGIN IMMEDIATE;")
        do {
            let statement = try prepare(
                "INSERT INTO member_memory_consent "
                    + "(member_id, enabled, consented_at, revision) VALUES (?, ?, ?, 0) "
                    + "ON CONFLICT(member_id) DO UPDATE SET "
                    + "enabled = excluded.enabled, "
                    + "consented_at = excluded.consented_at, "
                    + "revision = member_memory_consent.revision + 1;"
            )
            defer { sqlite3_finalize(statement) }
            try bind(memberID.rawValue, at: 1, in: statement)
            guard sqlite3_bind_int(statement, 2, enabled) == SQLITE_OK else {
                throw SQLiteMemberInteractionMemoryStoreError.operationFailed
            }
            if let consentedAt {
                try bind(consentedAt.timeIntervalSince1970, at: 3, in: statement)
            } else {
                guard sqlite3_bind_null(statement, 3) == SQLITE_OK else {
                    throw SQLiteMemberInteractionMemoryStoreError.operationFailed
                }
            }
            try step(statement, expecting: SQLITE_DONE)

            if enabled == 0 {
                let delete = try prepare(
                    "DELETE FROM member_memory_events WHERE member_id = ?;"
                )
                defer { sqlite3_finalize(delete) }
                try bind(memberID.rawValue, at: 1, in: delete)
                try step(delete, expecting: SQLITE_DONE)
            }
            try execute("COMMIT;")
        } catch let error as SQLiteMemberInteractionMemoryStoreError {
            try? execute("ROLLBACK;")
            throw error
        } catch {
            try? execute("ROLLBACK;")
            throw SQLiteMemberInteractionMemoryStoreError.operationFailed
        }
    }

    public func clearMemory(for memberID: MemberID) async throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try ensureMemoryConsentRow(for: memberID)
            let delete = try prepare("DELETE FROM member_memory_events WHERE member_id = ?;")
            defer { sqlite3_finalize(delete) }
            try bind(memberID.rawValue, at: 1, in: delete)
            try step(delete, expecting: SQLITE_DONE)
            try incrementMemoryRevision(for: memberID)
            try execute("COMMIT;")
        } catch let error as SQLiteMemberInteractionMemoryStoreError {
            try? execute("ROLLBACK;")
            throw error
        } catch {
            try? execute("ROLLBACK;")
            throw SQLiteMemberInteractionMemoryStoreError.operationFailed
        }
    }

    /// Performs retention maintenance for every member. Call this once during
    /// the Debug-Live composition startup before any session loads memory.
    public func pruneExpired(at now: Date) async throws {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw SQLiteMemberInteractionMemoryStoreError.invalidMemoryDate
        }
        try pruneExpiredMemory(at: now)
    }

    private struct MemoryConsentState {
        let enabled: Bool
        let consentedAt: Date?
        let revision: UInt64
    }

    private func memoryConsentState(
        for memberID: MemberID
    ) throws(SQLiteMemberInteractionMemoryStoreError) -> MemoryConsentState? {
        let statement = try prepare(
            "SELECT enabled, consented_at, revision FROM member_memory_consent "
                + "WHERE member_id = ? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(memberID.rawValue, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            guard sqlite3_errcode(connection.pointer) == SQLITE_DONE else {
                throw .operationFailed
            }
            return nil
        }

        let enabled = sqlite3_column_int(statement, 0) == 1
        let consentedAt: Date?
        if sqlite3_column_type(statement, 1) == SQLITE_NULL {
            consentedAt = nil
        } else {
            let value = sqlite3_column_double(statement, 1)
            let date = Date(timeIntervalSince1970: value)
            guard value.isFinite, date.timeIntervalSinceReferenceDate.isFinite else {
                throw .invalidStoredMemory
            }
            consentedAt = date
        }
        let rawRevision = sqlite3_column_int64(statement, 2)
        guard rawRevision >= 0 else { throw .invalidStoredMemory }
        return MemoryConsentState(
            enabled: enabled,
            consentedAt: consentedAt,
            revision: UInt64(rawRevision)
        )
    }

    private func consentStatus(
        from state: MemoryConsentState
    ) throws(SQLiteMemberInteractionMemoryStoreError) -> MemberMemoryConsentStatus {
        guard state.enabled else { return .disabled }
        guard let consentedAt = state.consentedAt else {
            throw .invalidStoredMemory
        }
        return .enabled(consentedAt: consentedAt)
    }

    private func retentionCutoff(
        at now: Date
    ) throws(SQLiteMemberInteractionMemoryStoreError) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MemberInteractionMemoryPolicy.storeTimeZone
        guard let cutoff = calendar.date(
            byAdding: .day,
            value: -MemberInteractionMemoryPolicy.retentionDays,
            to: now
        ) else {
            throw .invalidMemoryDate
        }
        return cutoff
    }

    private func hasExpiredMemory(
        for memberID: MemberID,
        cutoff: Date
    ) throws(SQLiteMemberInteractionMemoryStoreError) -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM member_memory_events WHERE member_id = ? AND recorded_at < ? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(memberID.rawValue, at: 1, in: statement)
        try bind(cutoff.timeIntervalSince1970, at: 2, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw .operationFailed
        }
    }

    private func pruneExpiredMemory(
        for memberID: MemberID,
        at now: Date
    ) throws(SQLiteMemberInteractionMemoryStoreError) {
        let cutoff = try retentionCutoff(at: now)
        // Use the member/time index before taking a write lock. Most welcomes
        // have nothing to prune and must remain read-only.
        guard try hasExpiredMemory(for: memberID, cutoff: cutoff) else { return }
        try execute("BEGIN IMMEDIATE;")
        do {
            let statement = try prepare(
                "DELETE FROM member_memory_events WHERE member_id = ? AND recorded_at < ?;"
            )
            defer { sqlite3_finalize(statement) }
            try bind(memberID.rawValue, at: 1, in: statement)
            try bind(cutoff.timeIntervalSince1970, at: 2, in: statement)
            try step(statement, expecting: SQLITE_DONE)
            if sqlite3_changes(connection.pointer) > 0 {
                try incrementMemoryRevision(for: memberID)
            }
            try execute("COMMIT;")
        } catch let error as SQLiteMemberInteractionMemoryStoreError {
            try? execute("ROLLBACK;")
            throw error
        } catch {
            try? execute("ROLLBACK;")
            throw .operationFailed
        }
    }

    private func pruneExpiredMemory(
        at now: Date
    ) throws(SQLiteMemberInteractionMemoryStoreError) {
        let cutoff = try retentionCutoff(at: now)

        try execute("BEGIN IMMEDIATE;")
        do {
            try pruneExpiredMemory(cutoff: cutoff)
            try execute("COMMIT;")
        } catch let error as SQLiteMemberInteractionMemoryStoreError {
            try? execute("ROLLBACK;")
            throw error
        } catch {
            try? execute("ROLLBACK;")
            throw .operationFailed
        }
    }

    private func pruneExpiredMemory(
        cutoff: Date
    ) throws(SQLiteMemberInteractionMemoryStoreError) {
        let membersStatement = try prepare(
            "SELECT DISTINCT member_id FROM member_memory_events WHERE recorded_at < ?;"
        )
        defer { sqlite3_finalize(membersStatement) }
        try bind(cutoff.timeIntervalSince1970, at: 1, in: membersStatement)
        var affectedMemberIDs: [String] = []
        memberRows: while true {
            switch sqlite3_step(membersStatement) {
            case SQLITE_ROW:
                guard let value = stringColumn(from: membersStatement, at: 0) else {
                    throw .invalidStoredMemory
                }
                affectedMemberIDs.append(value)
            case SQLITE_DONE:
                break memberRows
            default:
                throw .operationFailed
            }
        }

        let delete = try prepare(
            "DELETE FROM member_memory_events WHERE recorded_at < ?;"
        )
        defer { sqlite3_finalize(delete) }
        try bind(cutoff.timeIntervalSince1970, at: 1, in: delete)
        try step(delete, expecting: SQLITE_DONE)

        for rawValue in affectedMemberIDs {
            let statement = try prepare(
                "UPDATE member_memory_consent SET revision = revision + 1 WHERE member_id = ?;"
            )
            defer { sqlite3_finalize(statement) }
            try bind(rawValue, at: 1, in: statement)
            try step(statement, expecting: SQLITE_DONE)
        }
    }

    private func incrementMemoryRevision(
        for memberID: MemberID
    ) throws(SQLiteMemberInteractionMemoryStoreError) {
        let statement = try prepare(
            "UPDATE member_memory_consent SET revision = revision + 1 WHERE member_id = ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(memberID.rawValue, at: 1, in: statement)
        try step(statement, expecting: SQLITE_DONE)
        guard sqlite3_changes(connection.pointer) == 1 else {
            throw .operationFailed
        }
    }

    private func ensureMemoryConsentRow(
        for memberID: MemberID
    ) throws(SQLiteMemberInteractionMemoryStoreError) {
        let statement = try prepare(
            "INSERT OR IGNORE INTO member_memory_consent "
                + "(member_id, enabled, consented_at, revision) VALUES (?, 0, NULL, 0);"
        )
        defer { sqlite3_finalize(statement) }
        try bind(memberID.rawValue, at: 1, in: statement)
        try step(statement, expecting: SQLITE_DONE)
    }

    private func decodeMemoryEvent(
        from statement: OpaquePointer
    ) throws(SQLiteMemberInteractionMemoryStoreError) -> MemberMemoryEvent {
        guard let eventID = stringColumn(from: statement, at: 0),
              let interactionID = stringColumn(from: statement, at: 1),
              let kindValue = stringColumn(from: statement, at: 2),
              let sourceValue = stringColumn(from: statement, at: 3),
              let kind = memoryEventKind(fromWireValue: kindValue),
              let source = memorySource(fromWireValue: sourceValue)
        else {
            throw .invalidStoredMemory
        }
        let recordedValue = sqlite3_column_double(statement, 4)
        let recordedAt = Date(timeIntervalSince1970: recordedValue)
        guard recordedValue.isFinite, recordedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw .invalidStoredMemory
        }
        let disclosure: MemberExerciseDisclosure?
        if sqlite3_column_type(statement, 5) == SQLITE_NULL {
            disclosure = nil
        } else {
            guard let value = stringColumn(from: statement, at: 5),
                  let decoded = memoryDisclosure(fromWireValue: value)
            else {
                throw .invalidStoredMemory
            }
            disclosure = decoded
        }

        let event = MemberMemoryEvent(
            eventID: eventID,
            interactionID: interactionID,
            kind: kind,
            source: source,
            recordedAt: recordedAt,
            exerciseDisclosure: disclosure
        )
        try validateMemoryEvent(event, stored: true)
        return event
    }

    private func validateMemoryEvent(
        _ event: MemberMemoryEvent,
        stored: Bool = false
    ) throws(SQLiteMemberInteractionMemoryStoreError) {
        guard !event.eventID.isEmpty, !event.interactionID.isEmpty,
              event.recordedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw stored ? .invalidStoredMemory : .invalidMemoryEvent
        }
        switch (event.kind, event.source, event.exerciseDisclosure) {
        case (.meeting, .lumiObserved, nil),
             (.exerciseDisclosure, .memberReported, .some(.completedToday)):
            return
        default:
            throw stored ? .invalidStoredMemory : .invalidMemoryEvent
        }
    }

    private func stringColumn(
        from statement: OpaquePointer,
        at index: Int32
    ) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
            String(validatingCString: $0)
        }
    }

    private func memoryKindWireValue(_ kind: MemberMemoryEventKind) -> String {
        switch kind {
        case .meeting:
            "meeting"
        case .exerciseDisclosure:
            "exerciseDisclosure"
        }
    }

    private func memorySourceWireValue(_ source: MemberMemorySource) -> String {
        switch source {
        case .lumiObserved:
            "lumiObserved"
        case .memberReported:
            "memberReported"
        }
    }

    private func memoryDisclosureWireValue(
        _ disclosure: MemberExerciseDisclosure
    ) -> String {
        switch disclosure {
        case .preparing:
            "preparing"
        case .justCompleted:
            "justCompleted"
        case .completedToday:
            "completedToday"
        }
    }

    private func memoryEventKind(
        fromWireValue value: String
    ) -> MemberMemoryEventKind? {
        switch value {
        case "meeting":
            .meeting
        case "exerciseDisclosure":
            .exerciseDisclosure
        default:
            nil
        }
    }

    private func memorySource(
        fromWireValue value: String
    ) -> MemberMemorySource? {
        switch value {
        case "lumiObserved":
            .lumiObserved
        case "memberReported":
            .memberReported
        default:
            nil
        }
    }

    private func memoryDisclosure(
        fromWireValue value: String
    ) -> MemberExerciseDisclosure? {
        switch value {
        case "preparing":
            .preparing
        case "justCompleted":
            .justCompleted
        case "completedToday":
            .completedToday
        default:
            nil
        }
    }

    private func execute(
        _ sql: String
    ) throws(SQLiteMemberInteractionMemoryStoreError) {
        guard sqlite3_exec(connection.pointer, sql, nil, nil, nil) == SQLITE_OK else {
            throw .operationFailed
        }
    }

    private func prepare(
        _ sql: String
    ) throws(SQLiteMemberInteractionMemoryStoreError) -> OpaquePointer {
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
    ) throws(SQLiteMemberInteractionMemoryStoreError) {
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

    private func bind(
        _ value: Double,
        at index: Int32,
        in statement: OpaquePointer
    ) throws(SQLiteMemberInteractionMemoryStoreError) {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw .operationFailed
        }
    }

    private func step(
        _ statement: OpaquePointer,
        expecting expectedResult: Int32
    ) throws(SQLiteMemberInteractionMemoryStoreError) {
        guard sqlite3_step(statement) == expectedResult else { throw .operationFailed }
    }

    private static func createSchema(
        _ database: OpaquePointer
    ) throws(SQLiteMemberInteractionMemoryStoreError) {
        let sql = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS member_memory_consent (
            member_id TEXT PRIMARY KEY NOT NULL,
            enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
            consented_at REAL,
            revision INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS member_memory_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            member_id TEXT NOT NULL,
            event_id TEXT NOT NULL,
            interaction_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            source TEXT NOT NULL,
            recorded_at REAL NOT NULL,
            exercise_disclosure TEXT,
            UNIQUE(member_id, event_id),
            UNIQUE(member_id, interaction_id, kind)
        );
        CREATE INDEX IF NOT EXISTS member_memory_events_member_time
            ON member_memory_events(member_id, recorded_at);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw .operationFailed
        }
    }
}

private final class MemorySQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close_v2(pointer)
    }
}

/// Backup policy for the separate interaction-memory SQLite file. The main
/// identity calibration database remains outside this directory.
public enum SQLiteMemberInteractionMemoryStoreMaintenance {
    /// Excludes a dedicated interaction-memory directory before SQLite opens
    /// it. Any WAL/SHM files SQLite creates later inherit the directory's
    /// backup exclusion without touching the identity calibration directory.
    public static func excludeDirectoryFromBackup(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = directoryURL
        try mutableURL.setResourceValues(values)
    }

    public static func excludeDatabaseFromBackup(
        databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let sidecars = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        for url in sidecars where fileManager.fileExists(atPath: url.path) {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        }
    }
}

#endif
