import Foundation
import LumiDomain
@testable import LumiInfrastructure
import Testing

@Suite("Brute-force cosine face matcher")
struct BruteForceCosineFaceMatcherTests {
    @Test("returns top two distinct members and their ambiguity margin")
    func returnsTopTwoEvidence() throws {
        let query = try FaceEmbedding(modelVersion: "sface-4.10.0", components: [1, 0])
        let memberA = try MemberID(rawValue: "member-a")
        let memberB = try MemberID(rawValue: "member-b")
        let samples = [
            try StoredFaceEmbeddingSample(
                memberID: memberA,
                embedding: FaceEmbedding(modelVersion: "sface-4.10.0", components: [1, 0])
            ),
            try StoredFaceEmbeddingSample(
                memberID: memberB,
                embedding: FaceEmbedding(modelVersion: "sface-4.10.0", components: [0.8, 0.6])
            )
        ]

        let evidence = try BruteForceCosineFaceMatcher().evidence(for: query, against: samples)

        #expect(evidence.bestCandidate?.memberID == memberA)
        #expect(evidence.bestCandidate?.cosineSimilarity == 1)
        #expect(evidence.secondCandidate?.memberID == memberB)
        #expect(abs((evidence.margin ?? 0) - 0.2) < 0.000_001)
    }

    @Test("uses only the best sample per member when producing top two")
    func aggregatesSamplesByMember() throws {
        let query = try FaceEmbedding(modelVersion: "sface-4.10.0", components: [1, 0])
        let memberA = try MemberID(rawValue: "member-a")
        let memberB = try MemberID(rawValue: "member-b")
        let samples = [
            try sample(memberA, [0.7, 0.714_142]),
            try sample(memberA, [1, 0]),
            try sample(memberB, [0.9, 0.435_89])
        ]

        let evidence = try BruteForceCosineFaceMatcher().evidence(for: query, against: samples)

        #expect(evidence.bestCandidate?.memberID == memberA)
        #expect(evidence.secondCandidate?.memberID == memberB)
    }

    @Test("ignores samples from another model version")
    func ignoresIncompatibleModelVersion() throws {
        let query = try FaceEmbedding(modelVersion: "sface-4.10.0", components: [1, 0])
        let memberID = try MemberID(rawValue: "member-a")
        let incompatible = try StoredFaceEmbeddingSample(
            memberID: memberID,
            embedding: FaceEmbedding(modelVersion: "intel-0095", components: [1, 0])
        )

        let evidence = try BruteForceCosineFaceMatcher().evidence(
            for: query,
            against: [incompatible]
        )

        #expect(evidence.bestCandidate == nil)
        #expect(evidence.secondCandidate == nil)
        #expect(evidence.margin == nil)
    }

    @Test("rejects a same-model sample with a different dimension")
    func rejectsDimensionMismatch() throws {
        let query = try FaceEmbedding(modelVersion: "sface-4.10.0", components: [1, 0])
        let memberID = try MemberID(rawValue: "member-a")
        let malformed = try StoredFaceEmbeddingSample(
            memberID: memberID,
            embedding: FaceEmbedding(modelVersion: "sface-4.10.0", components: [1, 0, 0])
        )

        #expect(throws: FaceMatcherError.dimensionMismatch(expected: 2, actual: 3)) {
            try BruteForceCosineFaceMatcher().evidence(for: query, against: [malformed])
        }
    }

    @Test("ranks five enrollment samples for each of eight hundred members")
    func ranksFourThousandSamples() throws {
        let dimension = 128
        let query = try FaceEmbedding(
            modelVersion: "sface-4.10.0",
            components: [1] + Array(repeating: 0, count: dimension - 1)
        )
        let expectedID = try MemberID(rawValue: "member-0799")
        var samples: [StoredFaceEmbeddingSample] = []
        samples.reserveCapacity(4_000)

        for memberIndex in 0..<800 {
            let memberID = try MemberID(rawValue: String(format: "member-%04d", memberIndex))
            for sampleIndex in 0..<5 {
                var components = Array(repeating: Float(0), count: dimension)
                components[0] = memberIndex == 799 ? 1 : Float(memberIndex + 1) / 1_000
                components[(memberIndex + sampleIndex) % (dimension - 1) + 1] = 1
                samples.append(try StoredFaceEmbeddingSample(
                    memberID: memberID,
                    embedding: FaceEmbedding(
                        modelVersion: "sface-4.10.0",
                        components: components
                    )
                ))
            }
        }

        let evidence = try BruteForceCosineFaceMatcher().evidence(for: query, against: samples)

        #expect(samples.count == 4_000)
        #expect(evidence.bestCandidate?.memberID == expectedID)
        #expect(evidence.secondCandidate != nil)
    }

    @Test("ranks five enrollment samples for each of one thousand members with 256 dimensions")
    func ranksFiveThousandSamples256Dimensions() throws {
        let dimension = 256
        let query = try FaceEmbedding(
            modelVersion: "intel-0095",
            components: [1] + Array(repeating: 0, count: dimension - 1)
        )
        let expectedID = try MemberID(rawValue: "member-0999")
        var samples: [StoredFaceEmbeddingSample] = []
        samples.reserveCapacity(5_000)

        for memberIndex in 0..<1_000 {
            let memberID = try MemberID(rawValue: String(format: "member-%04d", memberIndex))
            for sampleIndex in 0..<5 {
                var components = Array(repeating: Float(0), count: dimension)
                components[0] = memberIndex == 999 ? 1 : Float(memberIndex + 1) / 1_500
                components[(memberIndex + sampleIndex) % (dimension - 1) + 1] = 1
                samples.append(try StoredFaceEmbeddingSample(
                    memberID: memberID,
                    embedding: FaceEmbedding(
                        modelVersion: "intel-0095",
                        components: components
                    )
                ))
            }
        }

        let evidence = try BruteForceCosineFaceMatcher().evidence(for: query, against: samples)

        #expect(samples.count == 5_000)
        #expect(evidence.bestCandidate?.memberID == expectedID)
        #expect(evidence.secondCandidate != nil)
    }

    @Test("rejects empty, zero, and non-finite embeddings")
    func rejectsInvalidEmbeddings() {
        #expect(throws: FaceEmbeddingError.empty) {
            try FaceEmbedding(modelVersion: "sface-4.10.0", components: [])
        }
        #expect(throws: FaceEmbeddingError.zeroMagnitude) {
            try FaceEmbedding(modelVersion: "sface-4.10.0", components: [0, 0])
        }
        #expect(throws: FaceEmbeddingError.nonFinite) {
            try FaceEmbedding(modelVersion: "sface-4.10.0", components: [.nan, 0])
        }
    }

    private func sample(_ memberID: MemberID, _ components: [Float]) throws -> StoredFaceEmbeddingSample {
        try StoredFaceEmbeddingSample(
            memberID: memberID,
            embedding: FaceEmbedding(modelVersion: "sface-4.10.0", components: components)
        )
    }
}
