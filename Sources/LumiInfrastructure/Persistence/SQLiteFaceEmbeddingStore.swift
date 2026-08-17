import Foundation
import LumiDomain

#if canImport(SQLite3)
import SQLite3

/// An opaque, versioned embedding owned by the Infrastructure identity layer.
/// Its bytes never cross into Domain or Application.
struct FaceEmbeddingRecord: Equatable, Sendable {
    let memberID: MemberID
    let modelVersion: String
    let embedding: Data
    let createdAt: Date

    init(memberID: MemberID, modelVersion: String, embedding: Data, createdAt: Date) {
        self.memberID = memberID
        self.modelVersion = modelVersion
        self.embedding = embedding
        self.createdAt = createdAt
    }
}

enum SQLiteFaceEmbeddingStoreError: Error, Equatable, Sendable {
    case invalidDatabase
    case statementPreparationFailed
    case operationFailed
    case invalidEmbedding
    case invalidStoredRecord
}

/// SQLite persistence for multiple enrollment samples per member.
///
/// This adapter intentionally does not select SFace confidence thresholds.
/// `modelVersion` isolates the SFace gallery from the Intel challenger and
/// makes later migration explicit and testable.
actor SQLiteFaceEmbeddingStore {
    private let connection: SQLiteEmbeddingConnection

    init(databaseURL: URL) throws(SQLiteFaceEmbeddingStoreError) {
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
        connection = SQLiteEmbeddingConnection(handle)
    }

    func save(_ record: FaceEmbeddingRecord) throws(SQLiteFaceEmbeddingStoreError) {
        let statement = try prepare(
            "INSERT INTO face_embeddings (member_id, model_version, embedding, created_at) VALUES (?, ?, ?, ?);"
        )
        defer { sqlite3_finalize(statement) }
        try bind(record.memberID.rawValue, at: 1, in: statement)
        try bind(record.modelVersion, at: 2, in: statement)
        try bind(record.embedding, at: 3, in: statement)
        guard sqlite3_bind_double(statement, 4, record.createdAt.timeIntervalSince1970) == SQLITE_OK else {
            throw .operationFailed
        }
        try step(statement, expecting: SQLITE_DONE)
    }

    func save(
        memberID: MemberID,
        embedding: FaceEmbedding,
        createdAt: Date
    ) throws(SQLiteFaceEmbeddingStoreError) {
        let encoded: Data
        do {
            encoded = try SFaceEmbeddingRecordCodec.encode(embedding)
        } catch {
            throw .invalidEmbedding
        }

        try save(FaceEmbeddingRecord(
            memberID: memberID,
            modelVersion: embedding.modelVersion,
            embedding: encoded,
            createdAt: createdAt
        ))
    }

    func records(for memberID: MemberID) throws(SQLiteFaceEmbeddingStoreError) -> [FaceEmbeddingRecord] {
        let statement = try prepare(
            "SELECT model_version, embedding, created_at FROM face_embeddings "
                + "WHERE member_id = ? ORDER BY created_at ASC, id ASC;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(memberID.rawValue, at: 1, in: statement)

        var records: [FaceEmbeddingRecord] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let modelPointer = sqlite3_column_text(statement, 0),
                  let modelVersion = modelPointer.withMemoryRebound(to: CChar.self, capacity: 1, {
                      String(validatingCString: $0)
                  })
            else { throw .invalidStoredRecord }

            let byteCount = Int(sqlite3_column_bytes(statement, 1))
            guard byteCount >= 0 else { throw .invalidStoredRecord }
            let embedding: Data
            if byteCount == 0 {
                embedding = Data()
            } else if let bytes = sqlite3_column_blob(statement, 1) {
                embedding = Data(bytes: bytes, count: byteCount)
            } else {
                throw .invalidStoredRecord
            }

            records.append(FaceEmbeddingRecord(
                memberID: memberID,
                modelVersion: modelVersion,
                embedding: embedding,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
            result = sqlite3_step(statement)
        }

        guard result == SQLITE_DONE else { throw .operationFailed }
        return records
    }

    func sFaceSamples() throws(SQLiteFaceEmbeddingStoreError) -> [StoredFaceEmbeddingSample] {
        try decodeSFaceSamples(from: sFaceRecords(memberID: nil))
    }

    func sFaceSamples(
        for memberID: MemberID
    ) throws(SQLiteFaceEmbeddingStoreError) -> [StoredFaceEmbeddingSample] {
        try decodeSFaceSamples(from: sFaceRecords(memberID: memberID))
    }

    func deleteRecords(for memberID: MemberID) throws(SQLiteFaceEmbeddingStoreError) {
        let statement = try prepare("DELETE FROM face_embeddings WHERE member_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(memberID.rawValue, at: 1, in: statement)
        try step(statement, expecting: SQLITE_DONE)
    }

    private func sFaceRecords(
        memberID: MemberID?
    ) throws(SQLiteFaceEmbeddingStoreError) -> [FaceEmbeddingRecord] {
        let sql: String
        if memberID == nil {
            sql = "SELECT member_id, model_version, embedding, created_at "
                + "FROM face_embeddings WHERE model_version = ? "
                + "ORDER BY member_id ASC, created_at ASC, id ASC;"
        } else {
            sql = "SELECT member_id, model_version, embedding, created_at "
                + "FROM face_embeddings WHERE member_id = ? AND model_version = ? "
                + "ORDER BY created_at ASC, id ASC;"
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var parameterIndex: Int32 = 1
        if let memberID {
            try bind(memberID.rawValue, at: parameterIndex, in: statement)
            parameterIndex += 1
        }
        try bind(
            SFaceEmbeddingRecordCodec.modelVersion,
            at: parameterIndex,
            in: statement
        )

        var records: [FaceEmbeddingRecord] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let memberPointer = sqlite3_column_text(statement, 0),
                  let rawMemberID = memberPointer.withMemoryRebound(
                      to: CChar.self,
                      capacity: 1,
                      {
                          String(validatingCString: $0)
                      }
                  ),
                  let storedMemberID = try? MemberID(rawValue: rawMemberID),
                  let storedModelPointer = sqlite3_column_text(statement, 1),
                  let storedModelVersion = storedModelPointer.withMemoryRebound(
                      to: CChar.self,
                      capacity: 1,
                      {
                          String(validatingCString: $0)
                      }
                  ),
                  storedModelVersion == SFaceEmbeddingRecordCodec.modelVersion
            else {
                throw .invalidStoredRecord
            }

            let byteCount = Int(sqlite3_column_bytes(statement, 2))
            guard byteCount >= 0 else { throw .invalidStoredRecord }
            let embedding: Data
            if byteCount == 0 {
                embedding = Data()
            } else if let bytes = sqlite3_column_blob(statement, 2) {
                embedding = Data(bytes: bytes, count: byteCount)
            } else {
                throw .invalidStoredRecord
            }

            records.append(FaceEmbeddingRecord(
                memberID: storedMemberID,
                modelVersion: storedModelVersion,
                embedding: embedding,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
            result = sqlite3_step(statement)
        }

        guard result == SQLITE_DONE else { throw .operationFailed }
        return records
    }

    private func decodeSFaceSamples(
        from records: [FaceEmbeddingRecord]
    ) throws(SQLiteFaceEmbeddingStoreError) -> [StoredFaceEmbeddingSample] {
        var samples: [StoredFaceEmbeddingSample] = []
        samples.reserveCapacity(records.count)
        for record in records {
            do {
                let embedding = try SFaceEmbeddingRecordCodec.decode(
                    record.embedding,
                    modelVersion: record.modelVersion
                )
                samples.append(StoredFaceEmbeddingSample(
                    memberID: record.memberID,
                    embedding: embedding
                ))
            } catch {
                throw .invalidStoredRecord
            }
        }
        return samples
    }

    private func prepare(_ sql: String) throws(SQLiteFaceEmbeddingStoreError) -> OpaquePointer {
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
    ) throws(SQLiteFaceEmbeddingStoreError) {
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
        _ value: Data,
        at index: Int32,
        in statement: OpaquePointer
    ) throws(SQLiteFaceEmbeddingStoreError) {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(value.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard result == SQLITE_OK else { throw .operationFailed }
    }

    private func step(
        _ statement: OpaquePointer,
        expecting expectedResult: Int32
    ) throws(SQLiteFaceEmbeddingStoreError) {
        guard sqlite3_step(statement) == expectedResult else { throw .operationFailed }
    }

    private static func createSchema(_ database: OpaquePointer) throws(SQLiteFaceEmbeddingStoreError) {
        let sql = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS face_embeddings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            member_id TEXT NOT NULL,
            model_version TEXT NOT NULL,
            embedding BLOB NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS face_embeddings_member
            ON face_embeddings(member_id, created_at);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw .operationFailed
        }
    }
}

private final class SQLiteEmbeddingConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}
#endif
