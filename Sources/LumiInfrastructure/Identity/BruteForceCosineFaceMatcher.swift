import Foundation
import LumiDomain

enum FaceEmbeddingError: Error, Equatable, Sendable {
    case empty
    case nonFinite
    case zeroMagnitude
}

/// Model-versioned, L2-normalized embedding owned by Infrastructure.
struct FaceEmbedding: Equatable, Sendable {
    let modelVersion: String
    let components: [Float]

    init(modelVersion: String, components: [Float]) throws(FaceEmbeddingError) {
        guard !components.isEmpty else { throw .empty }
        guard components.allSatisfy(\.isFinite) else { throw .nonFinite }

        let squaredMagnitude = components.reduce(Float.zero) { partial, component in
            partial + component * component
        }
        guard squaredMagnitude.isFinite else { throw .nonFinite }
        guard squaredMagnitude > 0 else { throw .zeroMagnitude }

        let magnitude = sqrt(squaredMagnitude)
        self.modelVersion = modelVersion
        self.components = components.map { $0 / magnitude }
    }
}

struct StoredFaceEmbeddingSample: Equatable, Sendable {
    let memberID: MemberID
    let embedding: FaceEmbedding
}

struct FaceMatchCandidate: Equatable, Sendable {
    let memberID: MemberID
    let cosineSimilarity: Double
}

struct FaceMatchEvidence: Equatable, Sendable {
    let bestCandidate: FaceMatchCandidate?
    let secondCandidate: FaceMatchCandidate?

    var margin: Double? {
        guard let bestCandidate, let secondCandidate else { return nil }
        return bestCandidate.cosineSimilarity - secondCandidate.cosineSimilarity
    }
}

enum FaceMatcherError: Error, Equatable, Sendable {
    case dimensionMismatch(expected: Int, actual: Int)
}

/// Exact linear cosine ranking for the current store-sized gallery.
///
/// It returns evidence only. Acceptance thresholds, ambiguity requirements,
/// quality gates, and temporal confirmation remain the Domain confidence
/// policy's responsibility and require store validation data.
struct BruteForceCosineFaceMatcher: Sendable {
    func evidence(
        for query: FaceEmbedding,
        against samples: [StoredFaceEmbeddingSample]
    ) throws(FaceMatcherError) -> FaceMatchEvidence {
        var bestByMember: [MemberID: Double] = [:]

        for sample in samples where sample.embedding.modelVersion == query.modelVersion {
            guard sample.embedding.components.count == query.components.count else {
                throw .dimensionMismatch(
                    expected: query.components.count,
                    actual: sample.embedding.components.count
                )
            }

            let similarity = zip(query.components, sample.embedding.components)
                .reduce(Double.zero) { partial, pair in
                    partial + Double(pair.0) * Double(pair.1)
                }
            bestByMember[sample.memberID] = max(
                bestByMember[sample.memberID] ?? -1,
                min(1, max(-1, similarity))
            )
        }

        let ranked = bestByMember.map {
            FaceMatchCandidate(memberID: $0.key, cosineSimilarity: $0.value)
        }.sorted {
            if $0.cosineSimilarity == $1.cosineSimilarity {
                return $0.memberID.rawValue < $1.memberID.rawValue
            }
            return $0.cosineSimilarity > $1.cosineSimilarity
        }

        return FaceMatchEvidence(
            bestCandidate: ranked.first,
            secondCandidate: ranked.dropFirst().first
        )
    }
}
