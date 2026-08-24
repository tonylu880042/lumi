import Foundation
import LumiApplication
import LumiDomain
@testable import LumiInfrastructure
import Testing

@Suite("SQLite face embedding store")
struct SQLiteFaceEmbeddingStoreTests {
    @Test("stores multiple opaque samples with model version")
    func storesMultipleSamples() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
        let memberID = try MemberID(rawValue: "member-001")
        let first = FaceEmbeddingRecord(
            memberID: memberID,
            modelVersion: "sface-opencv-zoo-4.10.0-fp32",
            embedding: Data([1, 2, 3]),
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let second = FaceEmbeddingRecord(
            memberID: memberID,
            modelVersion: "sface-opencv-zoo-4.10.0-fp32",
            embedding: Data([4, 5, 6]),
            createdAt: Date(timeIntervalSince1970: 200)
        )

        try await store.save(first)
        try await store.save(second)

        let records = try await store.records(for: memberID)
        #expect(records == [first, second])
    }

    @Test("deletes every sample for a member without affecting another member")
    func deletesMemberSamples() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
        let firstMember = try MemberID(rawValue: "member-001")
        let secondMember = try MemberID(rawValue: "member-002")
        let firstRecord = FaceEmbeddingRecord(
            memberID: firstMember,
            modelVersion: "sface-opencv-zoo-4.10.0-fp32",
            embedding: Data([1]),
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let secondRecord = FaceEmbeddingRecord(
            memberID: secondMember,
            modelVersion: "sface-opencv-zoo-4.10.0-fp32",
            embedding: Data([2]),
            createdAt: Date(timeIntervalSince1970: 100)
        )

        try await store.save(firstRecord)
        try await store.save(secondRecord)
        try await store.deleteRecords(for: firstMember)

        #expect(try await store.records(for: firstMember).isEmpty)
        #expect(try await store.records(for: secondMember) == [secondRecord])
    }

    @Test("reopening preserves opaque samples byte-for-byte")
    func reopensWithExactBytes() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let memberID = try MemberID(rawValue: "member-001")
        let record = FaceEmbeddingRecord(
            memberID: memberID,
            modelVersion: "sface-opencv-zoo-4.10.0-fp32",
            embedding: Data([0, 127, 255]),
            createdAt: Date(timeIntervalSince1970: 123.5)
        )

        do {
            let store = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
            try await store.save(record)
        }

        let reopened = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
        #expect(try await reopened.records(for: memberID) == [record])
    }

    @Test("stores typed SFace samples with deterministic gallery and member ordering")
    func storesTypedSamplesWithDeterministicOrdering() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let memberA = try MemberID(rawValue: "member-a")
        let memberB = try MemberID(rawValue: "member-b")
        let aEarly = try makeEmbedding(axis: 0)
        let aLate = try makeEmbedding(axis: 1)
        let bEarly = try makeEmbedding(axis: 2)
        let bLate = try makeEmbedding(axis: 3)

        do {
            let store = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
            try await store.save(
                memberID: memberB,
                embedding: bLate,
                createdAt: Date(timeIntervalSince1970: 200)
            )
            try await store.save(
                memberID: memberA,
                embedding: aLate,
                createdAt: Date(timeIntervalSince1970: 300)
            )
            try await store.save(
                memberID: memberA,
                embedding: aEarly,
                createdAt: Date(timeIntervalSince1970: 100)
            )
            try await store.save(
                memberID: memberB,
                embedding: bEarly,
                createdAt: Date(timeIntervalSince1970: 50)
            )

            let all = try await store.sFaceSamples()
            #expect(all.count == 4)
            #expect(all[0].memberID == memberA)
            #expect(all[0].embedding == aEarly)
            #expect(all[1].memberID == memberA)
            #expect(all[1].embedding == aLate)
            #expect(all[2].memberID == memberB)
            #expect(all[2].embedding == bEarly)
            #expect(all[3].memberID == memberB)
            #expect(all[3].embedding == bLate)

            let memberSamples = try await store.sFaceSamples(for: memberA)
            #expect(memberSamples == [
                StoredFaceEmbeddingSample(memberID: memberA, embedding: aEarly),
                StoredFaceEmbeddingSample(memberID: memberA, embedding: aLate)
            ])
        }

        let reopened = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
        let reopenedSamples = try await reopened.sFaceSamples()
        #expect(reopenedSamples.count == 4)
        #expect(reopenedSamples[0].embedding == aEarly)
        #expect(reopenedSamples[1].embedding == aLate)
        #expect(reopenedSamples[2].embedding == bEarly)
        #expect(reopenedSamples[3].embedding == bLate)
    }

    @Test("typed SFace queries isolate rows from other model versions")
    func typedQueriesFilterOtherModelRows() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let member = try MemberID(rawValue: "member-001")
        let sFaceEmbedding = try makeEmbedding(axis: 0)
        let store = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)

        try await store.save(
            memberID: member,
            embedding: sFaceEmbedding,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        try await store.save(FaceEmbeddingRecord(
            memberID: member,
            modelVersion: "intel-face-reidentification-retail-0095",
            embedding: try SFaceEmbeddingRecordCodec.encode(sFaceEmbedding),
            createdAt: Date(timeIntervalSince1970: 200)
        ))

        #expect(try await store.sFaceSamples() == [
            StoredFaceEmbeddingSample(memberID: member, embedding: sFaceEmbedding)
        ])
        #expect(try await store.sFaceSamples(for: member) == [
            StoredFaceEmbeddingSample(memberID: member, embedding: sFaceEmbedding)
        ])
    }

    @Test("typed reads fail the whole query for a corrupt exact-version row")
    func corruptTypedRowFailsClosedWithoutPartialResult() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let member = try MemberID(rawValue: "member-001")
        let store = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
        try await store.save(FaceEmbeddingRecord(
            memberID: member,
            modelVersion: SFaceEmbeddingRecordCodec.modelVersion,
            embedding: try SFaceEmbeddingRecordCodec.encode(try makeEmbedding(axis: 0)),
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        try await store.save(FaceEmbeddingRecord(
            memberID: member,
            modelVersion: SFaceEmbeddingRecordCodec.modelVersion,
            embedding: Data([0x01, 0x02, 0x03]),
            createdAt: Date(timeIntervalSince1970: 200)
        ))

        await #expect(throws: SQLiteFaceEmbeddingStoreError.invalidStoredRecord) {
            _ = try await store.sFaceSamples()
        }
    }

    @Test("typed save rejects wrong model version or component count without inserting")
    func typedSaveRejectsInvalidEmbedding() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let member = try MemberID(rawValue: "member-001")
        let store = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
        let wrongVersion = try FaceEmbedding(
            modelVersion: "intel-face-reidentification-retail-0095",
            components: [1]
        )
        let wrongCount = try FaceEmbedding(
            modelVersion: SFaceEmbeddingRecordCodec.modelVersion,
            components: [1, 0]
        )

        await #expect(throws: SQLiteFaceEmbeddingStoreError.invalidEmbedding) {
            try await store.save(
                memberID: member,
                embedding: wrongVersion,
                createdAt: Date(timeIntervalSince1970: 100)
            )
        }
        await #expect(throws: SQLiteFaceEmbeddingStoreError.invalidEmbedding) {
            try await store.save(
                memberID: member,
                embedding: wrongCount,
                createdAt: Date(timeIntervalSince1970: 200)
            )
        }
        #expect(try await store.records(for: member).isEmpty)
    }

    @Test("visitor enrollment atomically stores profile and exactly three samples")
    func visitorEnrollmentStoresProfileAndSamples() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let memberID = try MemberID(rawValue: "local-uuid")
        let address = try VoiceMemberAddress(spokenLabel: "Tony")
        let embeddings = try [0, 1, 2].map(makeEmbedding)

        do {
            let store = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
            try await store.commitVisitorEnrollment(
                memberID: memberID,
                address: address,
                consentedAt: Date(timeIntervalSince1970: 100),
                completedAt: Date(timeIntervalSince1970: 200),
                embeddings: embeddings
            )
        }

        let reopened = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
        #expect(try await reopened.address(for: memberID) == address)
        #expect(try await reopened.sFaceSamples(for: memberID) == [
            StoredFaceEmbeddingSample(memberID: memberID, embedding: embeddings[0]),
            StoredFaceEmbeddingSample(memberID: memberID, embedding: embeddings[1]),
            StoredFaceEmbeddingSample(memberID: memberID, embedding: embeddings[2])
        ])
    }

    @Test("duplicate local member ID rolls back without adding embeddings")
    func duplicateVisitorEnrollmentRollsBack() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
        let memberID = try MemberID(rawValue: "local-duplicate")
        let originalAddress = try VoiceMemberAddress(spokenLabel: "Tony")
        let firstEmbeddings = try [0, 1, 2].map(makeEmbedding)
        try await store.commitVisitorEnrollment(
            memberID: memberID,
            address: originalAddress,
            consentedAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 200),
            embeddings: firstEmbeddings
        )

        await #expect(throws: SQLiteFaceEmbeddingStoreError.operationFailed) {
            try await store.commitVisitorEnrollment(
                memberID: memberID,
                address: VoiceMemberAddress(spokenLabel: "Ruby"),
                consentedAt: Date(timeIntervalSince1970: 300),
                completedAt: Date(timeIntervalSince1970: 400),
                embeddings: try [3, 4, 5].map(makeEmbedding)
            )
        }

        #expect(try await store.address(for: memberID) == originalAddress)
        #expect(try await store.sFaceSamples(for: memberID).count == 3)
    }

    private func makeEmbedding(axis: Int) throws -> FaceEmbedding {
        var components = Array(repeating: Float.zero, count: 128)
        components[axis] = 1
        return try FaceEmbedding(
            modelVersion: SFaceEmbeddingRecordCodec.modelVersion,
            components: components
        )
    }

    private func temporaryDatabaseURL() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-face-embedding-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }
}
