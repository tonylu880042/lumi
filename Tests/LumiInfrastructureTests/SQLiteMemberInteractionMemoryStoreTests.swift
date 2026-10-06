import Foundation
import LumiApplication
import LumiDomain
import LumiInfrastructure
import Testing
import SQLite3

@Suite("SQLite member interaction memory")
struct SQLiteMemberInteractionMemoryStoreTests {
    @Test("connection resources are released after an outstanding statement is finalized")
    func deferredConnectionCloseReleasesResources() throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        var store: SQLiteMemberInteractionMemoryStore? =
            try SQLiteMemberInteractionMemoryStore(databaseURL: databaseURL)
        let pointer = try databasePointer(in: try #require(store))
        let probe = ConnectionDestructionProbe()
        try #require(sqlite3_create_function_v2(
            pointer, "close_probe", 0, SQLITE_UTF8,
            Unmanaged.passRetained(probe).toOpaque(),
            { context, _, _ in sqlite3_result_null(context) }, nil, nil,
            { context in
                guard let context else { return }
                Unmanaged<ConnectionDestructionProbe>.fromOpaque(context)
                    .takeRetainedValue().markDestroyed()
            }
        ) == SQLITE_OK)
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(pointer, "SELECT 1;", -1, &statement, nil) == SQLITE_OK)
        try #require(sqlite3_step(statement) == SQLITE_ROW)

        store = nil
        #expect(!probe.isDestroyed)
        #expect(sqlite3_finalize(statement) == SQLITE_OK)
        #expect(probe.isDestroyed)
        // Release the leaked handle when running this regression against close().
        if !probe.isDestroyed { sqlite3_close(pointer) }
    }

    @Test("loading unexpired memory succeeds while another connection owns the write lock")
    func readDoesNotRequireWriteLock() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMemberInteractionMemoryStore(databaseURL: databaseURL)
        let memberID = try MemberID(rawValue: "member-a")
        let now = date("2026-09-18T12:00:00+08:00")
        try await store.setConsent(for: memberID, status: .enabled(consentedAt: now))
        let before = try await store.loadBatch(for: memberID, at: now)
        let event = MemberMemoryEvent(
            eventID: "meeting:today", interactionID: "today", kind: .meeting,
            source: .lumiObserved, recordedAt: now, exerciseDisclosure: nil
        )
        let appended = try await store.append(
            event, for: memberID, expectedRevision: before.revision
        )
        let writer = try openDatabase(databaseURL)
        defer { sqlite3_close(writer) }
        try #require(sqlite3_exec(writer, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil) }

        let batch = try await store.loadBatch(for: memberID, at: now)
        #expect(batch.events == [event])
        #expect(batch.revision == appended.revision)
    }

    @Test("loading a member prunes only her expired events and invalidates her stale revision")
    func readPrunesOnlyCurrentMember() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMemberInteractionMemoryStore(databaseURL: databaseURL)
        let first = try MemberID(rawValue: "member-a")
        let second = try MemberID(rawValue: "member-b")
        let now = date("2026-09-18T12:00:00+08:00")
        let old = date("2026-06-19T12:00:00+08:00")
        for memberID in [first, second] {
            try await store.setConsent(for: memberID, status: .enabled(consentedAt: old))
            let batch = try await store.loadBatch(for: memberID, at: old)
            _ = try await store.append(
                MemberMemoryEvent(
                    eventID: "meeting:old", interactionID: "old", kind: .meeting,
                    source: .lumiObserved, recordedAt: old, exerciseDisclosure: nil
                ), for: memberID, expectedRevision: batch.revision
            )
        }
        let batch = try await store.loadBatch(for: first, at: now)
        #expect(batch.events.isEmpty)
        #expect(batch.revision == 2)
        let reader = try openDatabase(databaseURL)
        defer { sqlite3_close(reader) }
        #expect(try integerQuery(reader,
            "SELECT COUNT(*) FROM member_memory_events WHERE member_id = 'member-b';") == 1)
        #expect(try integerQuery(reader,
            "SELECT revision FROM member_memory_consent WHERE member_id = 'member-b';") == 1)
        let stale = try await store.append(
            MemberMemoryEvent(
                eventID: "meeting:late", interactionID: "late", kind: .meeting,
                source: .lumiObserved, recordedAt: now, exerciseDisclosure: nil
            ), for: first, expectedRevision: 1
        )
        #expect(stale.outcome == .rejected)

        try await store.pruneExpired(at: now)
        #expect(try integerQuery(reader, "SELECT COUNT(*) FROM member_memory_events;") == 0)
        #expect(try integerQuery(reader,
            "SELECT revision FROM member_memory_consent WHERE member_id = 'member-b';") == 2)
    }

    @Test("separate memory store rejects session-only persistence directly")
    func separateStoreRejectsSessionOnlyEvent() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("MemberInteractionMemory.sqlite")
        let store = try SQLiteMemberInteractionMemoryStore(databaseURL: databaseURL)
        let memberID = try MemberID(rawValue: "member-memory")
        let now = date("2026-09-18T12:00:00+08:00")
        try await store.setConsent(
            for: memberID,
            status: .enabled(consentedAt: now)
        )
        let batch = try await store.loadBatch(for: memberID, at: now)
        let event = MemberMemoryEvent(
            eventID: "exercise:session",
            interactionID: "session",
            kind: .exerciseDisclosure,
            source: .memberReported,
            recordedAt: now,
            exerciseDisclosure: .preparing
        )

        await #expect(throws: SQLiteMemberInteractionMemoryStoreError.invalidMemoryEvent) {
            _ = try await store.append(
                event,
                for: memberID,
                expectedRevision: batch.revision
            )
        }
    }

    @Test("startup pruning is explicit and backup exclusion covers the memory directory")
    func startupMaintenanceUsesDedicatedDirectory() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try SQLiteMemberInteractionMemoryStoreMaintenance.excludeDirectoryFromBackup(
            directoryURL: directory
        )
        let values = try directory.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        #expect(values.isExcludedFromBackup == true)

        let databaseURL = directory.appendingPathComponent("MemberInteractionMemory.sqlite")
        let store = try SQLiteMemberInteractionMemoryStore(databaseURL: databaseURL)
        try await store.pruneExpired(at: date("2026-09-18T12:00:00+08:00"))
    }

    @Test("correction removes only the current-day persistent disclosure")
    func correctionRemovesCurrentDayDisclosure() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMemberInteractionMemoryStore(
            databaseURL: directory.appendingPathComponent("MemberInteractionMemory.sqlite")
        )
        let memberID = try MemberID(rawValue: "member-memory")
        let now = date("2026-09-18T12:00:00+08:00")
        try await store.setConsent(
            for: memberID,
            status: .enabled(consentedAt: now)
        )
        let initial = try await store.loadBatch(for: memberID, at: now)
        let disclosure = MemberMemoryEvent(
            eventID: "exercise:today",
            interactionID: "today",
            kind: .exerciseDisclosure,
            source: .memberReported,
            recordedAt: now,
            exerciseDisclosure: .completedToday
        )
        let append = try await store.append(
            disclosure,
            for: memberID,
            expectedRevision: initial.revision
        )
        #expect(append.outcome == .appended)
        #expect(append.revision == initial.revision + 1)
        let afterAppend = try await store.loadBatch(for: memberID, at: now)
        #expect(afterAppend.revision == append.revision)
        #expect(afterAppend.events == [disclosure])
        let correction = try await store.correctExerciseDisclosure(
            for: memberID,
            at: now,
            expectedRevision: append.revision
        )
        #expect(correction.revision == append.revision + 1)
        #expect(correction.outcome == .corrected)
        #expect(try await store.loadBatch(for: memberID, at: now).events.isEmpty)
    }

    @Test("persists consent and deduplicates repeated interaction IDs")
    func persistsConsentAndDeduplicates() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMemberInteractionMemoryStore(databaseURL: databaseURL)
        let memberID = try MemberID(rawValue: "member-memory")
        let now = date("2026-09-18T12:00:00+08:00")
        let event = MemberMemoryEvent(
            eventID: "meeting:session-1",
            interactionID: "session-1",
            kind: .meeting,
            source: .lumiObserved,
            recordedAt: now,
            exerciseDisclosure: nil
        )

        try await store.setConsent(
            for: memberID,
            status: .enabled(consentedAt: now)
        )
        #expect(
            try await store.consentStatus(for: memberID)
                == .enabled(consentedAt: now)
        )
        let before = try await store.loadBatch(for: memberID, at: now)
        #expect(before.events.isEmpty)

        #expect(
            (try await store.append(event, for: memberID, expectedRevision: before.revision)).outcome
                == .appended
        )
        #expect(
            (try await store.append(event, for: memberID, expectedRevision: before.revision + 1)).outcome
                == .duplicate
        )

        let after = try await store.loadBatch(for: memberID, at: now)
        #expect(after.events == [event])
        #expect(after.revision == before.revision + 1)

        let reopened = try SQLiteMemberInteractionMemoryStore(databaseURL: databaseURL)
        let persisted = try await reopened.loadBatch(for: memberID, at: now)
        #expect(persisted.events == [event])
        #expect(persisted.revision == after.revision)
    }

    @Test("explicit maintenance purges expired events for every member")
    func purgesExpiredEventsAcrossMembers() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMemberInteractionMemoryStore(databaseURL: databaseURL)
        let first = try MemberID(rawValue: "member-a")
        let second = try MemberID(rawValue: "member-b")
        let now = date("2026-09-18T12:00:00+08:00")
        let old = date("2026-06-19T12:00:00+08:00")

        for memberID in [first, second] {
            try await store.setConsent(
                for: memberID,
                status: .enabled(consentedAt: now)
            )
            let batch = try await store.loadBatch(for: memberID, at: old)
            let event = MemberMemoryEvent(
                eventID: "meeting:\(memberID.rawValue)",
                interactionID: "session:\(memberID.rawValue)",
                kind: .meeting,
                source: .lumiObserved,
                recordedAt: old,
                exerciseDisclosure: nil
            )
            #expect(
                (try await store.append(event, for: memberID, expectedRevision: batch.revision)).outcome
                    == .appended
            )
        }

        try await store.pruneExpired(at: now)
        let firstBefore = try await store.loadBatch(for: first, at: now)
        #expect(firstBefore.events.isEmpty)
        let secondAfter = try await store.loadBatch(for: second, at: now)
        #expect(secondAfter.events.isEmpty)
        #expect(secondAfter.revision == 2)
    }

    @Test("clear removes memory events and invalidates a stale session revision")
    func clearInvalidatesStaleSession() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMemberInteractionMemoryStore(databaseURL: databaseURL)
        let identityDatabaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: identityDatabaseURL) }
        let identityStore = try SQLiteMemberDataStore(databaseURL: identityDatabaseURL)
        let memberID = try MemberID(rawValue: "member-memory")
        let now = date("2026-09-18T12:00:00+08:00")
        try await identityStore.saveMember(Member(id: memberID, displayName: "小芳"))
        try await store.setConsent(for: memberID, status: .enabled(consentedAt: now))
        let initial = try await store.loadBatch(for: memberID, at: now)
        let event = MemberMemoryEvent(
            eventID: "meeting:session-1",
            interactionID: "session-1",
            kind: .meeting,
            source: .lumiObserved,
            recordedAt: now,
            exerciseDisclosure: nil
        )
        #expect(
            (try await store.append(event, for: memberID, expectedRevision: initial.revision)).outcome
                == .appended
        )

        try await store.clearMemory(for: memberID)
        let cleared = try await store.loadBatch(for: memberID, at: now)
        #expect(cleared.events.isEmpty)
        #expect(cleared.revision == initial.revision + 2)
        #expect(try await identityStore.member(for: memberID) == Member(id: memberID, displayName: "小芳"))
        #expect(
            (try await store.append(event, for: memberID, expectedRevision: initial.revision + 1)).outcome
                == .rejected
        )
    }

    @Test("disabled consent prevents a memory batch from being loaded")
    func disabledConsentFailsClosed() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMemberInteractionMemoryStore(databaseURL: databaseURL)
        let memberID = try MemberID(rawValue: "member-memory")
        let now = date("2026-09-18T12:00:00+08:00")

        try await store.setConsent(for: memberID, status: .disabled)
        await #expect(throws: SQLiteMemberInteractionMemoryStoreError.memoryDisabled) {
            _ = try await store.loadBatch(for: memberID, at: now)
        }
    }

    @Test("disabling consent clears events and stale revisions cannot return after re-enable")
    func disablingConsentClearsAndInvalidates() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMemberInteractionMemoryStore(databaseURL: databaseURL)
        let memberID = try MemberID(rawValue: "member-memory")
        let now = date("2026-09-18T12:00:00+08:00")
        try await store.setConsent(for: memberID, status: .enabled(consentedAt: now))
        let initial = try await store.loadBatch(for: memberID, at: now)
        let event = MemberMemoryEvent(
            eventID: "meeting:session-1",
            interactionID: "session-1",
            kind: .meeting,
            source: .lumiObserved,
            recordedAt: now,
            exerciseDisclosure: nil
        )
        #expect(
            (try await store.append(event, for: memberID, expectedRevision: initial.revision)).outcome
                == .appended
        )

        try await store.setConsent(for: memberID, status: .disabled)
        await #expect(throws: SQLiteMemberInteractionMemoryStoreError.memoryDisabled) {
            _ = try await store.loadBatch(for: memberID, at: now)
        }

        try await store.setConsent(for: memberID, status: .enabled(consentedAt: now))
        let reenabled = try await store.loadBatch(for: memberID, at: now)
        #expect(reenabled.events.isEmpty)
        #expect(reenabled.revision > initial.revision + 1)
        #expect(
            (try await store.append(event, for: memberID, expectedRevision: initial.revision + 1)).outcome
                == .rejected
        )
    }

    private func temporaryDatabaseURL() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-member-memory-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func openDatabase(_ url: URL) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        try #require(sqlite3_open(url.path, &pointer) == SQLITE_OK)
        return try #require(pointer)
    }

    private func databasePointer(in store: SQLiteMemberInteractionMemoryStore) throws -> OpaquePointer {
        // Inspect ownership without exposing the adapter's connection publicly.
        let connection = try #require(
            Mirror(reflecting: store).children.first { $0.label == "connection" }?.value
        )
        return try #require(
            Mirror(reflecting: connection).children.first { $0.label == "pointer" }?.value
                as? OpaquePointer
        )
    }

    private func integerQuery(_ pointer: OpaquePointer, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(pointer, sql, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-member-memory-\(UUID().uuidString)", isDirectory: true)
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        return formatter.date(from: value)!
    }
}

private final class ConnectionDestructionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var destroyed = false

    var isDestroyed: Bool { lock.withLock { destroyed } }

    func markDestroyed() { lock.withLock { destroyed = true } }
}
