import Foundation
import LumiDomain

/// Stable, payload-free failure for one enrollment-recording attempt.
enum SFaceEnrollmentSampleRecorderError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case failed

    var description: String {
        "SFace enrollment sample recorder failed."
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}

/// The outcome of one already-authorized enrollment sample attempt.
enum SFaceEnrollmentSampleResult: Equatable, Sendable {
    case noUsableFace
    case stored
}

/// Narrow asynchronous boundary for the composed frame embedding pipeline.
protocol SFaceFrameEmbeddingProducing: Sendable {
    func embedding(for frame: CameraFrame) async throws -> FaceEmbedding?
}

/// Narrow asynchronous boundary for typed SFace persistence.
protocol SFaceEnrollmentStoreWriting: Sendable {
    func save(
        memberID: MemberID,
        embedding: FaceEmbedding,
        createdAt: Date
    ) async throws
}

/// Records one embedding only after an upstream caller has obtained consent.
/// Consent, conversation state, identity selection, and enrollment limits stay
/// outside this Infrastructure value.
struct SFaceEnrollmentSampleRecorder: Sendable {
    private let pipeline: any SFaceFrameEmbeddingProducing
    private let store: any SFaceEnrollmentStoreWriting

    init(
        pipeline: any SFaceFrameEmbeddingProducing,
        store: any SFaceEnrollmentStoreWriting
    ) {
        self.pipeline = pipeline
        self.store = store
    }

    /// Attempts one frame and stores it only when a unique usable face exists.
    /// The `.stored` result deliberately carries no post-save count: a count
    /// query after a committed insert could fail and make a successful write
    /// look unsuccessful to a caller that retries.
    func record(
        frame: CameraFrame,
        for memberID: MemberID,
        at createdAt: Date
    ) async throws -> SFaceEnrollmentSampleResult {
        do {
            try Task.checkCancellation()
            guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw SFaceEnrollmentSampleRecorderError.failed
            }

            guard let embedding = try await pipeline.embedding(for: frame)
            else {
                try Task.checkCancellation()
                return .noUsableFace
            }
            try Task.checkCancellation()

            try await store.save(
                memberID: memberID,
                embedding: embedding,
                createdAt: createdAt
            )
            return .stored
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            // Cancellation wins a race with any generic stage/store failure.
            if Task.isCancelled {
                throw CancellationError()
            }
            throw SFaceEnrollmentSampleRecorderError.failed
        }
    }
}

extension SFaceFrameEmbeddingPipeline: SFaceFrameEmbeddingProducing {}

#if canImport(SQLite3)
extension SQLiteFaceEmbeddingStore: SFaceEnrollmentStoreWriting {}
#endif
