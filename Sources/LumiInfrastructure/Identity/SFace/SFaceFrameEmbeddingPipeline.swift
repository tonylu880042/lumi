import Foundation

/// Stable, payload-free failure for the frame-to-embedding composition.
enum SFaceFrameEmbeddingPipelineError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case failed

    var description: String {
        "SFace frame embedding pipeline failed."
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}

/// Narrow asynchronous Vision rectangle boundary used by the composition.
protocol VisionFaceDetecting: Sendable {
    func detect(frame: CameraFrame) async throws -> [DetectedFace]
}

/// Narrow asynchronous YuNet candidate boundary used by the composition.
protocol YuNetFaceCandidateDetecting: Sendable {
    func detect(frame: CameraFrame) async throws -> [DetectedFace]
}

/// Narrow asynchronous SFace embedding boundary used by the composition.
protocol SFaceEmbeddingInferring: Sendable {
    func embedding(for face: SFaceAlignedFace) async throws -> FaceEmbedding
}

/// Composes Vision target selection, YuNet candidate pairing, SFace alignment,
/// and embedding inference for one owned camera frame.
///
/// Vision remains authoritative for the frame-level face rectangle and
/// confidence. This type only returns an embedding when Vision produced one
/// face and exactly one YuNet candidate could be paired with it; it performs no
/// identity selection, matching, thresholding, enrollment, or persistence.
struct SFaceFrameEmbeddingPipeline: Sendable {
    private let visionDetector: any VisionFaceDetecting
    private let yuNetDetector: any YuNetFaceCandidateDetecting
    private let sFaceInference: any SFaceEmbeddingInferring
    private let targetSelector = FaceTargetSelector()
    private let pairer = VisionYuNetCandidatePairer()
    private let cropper = SFaceAlignmentCropper()

    init(
        visionDetector: any VisionFaceDetecting,
        yuNetDetector: any YuNetFaceCandidateDetecting,
        sFaceInference: any SFaceEmbeddingInferring
    ) {
        self.visionDetector = visionDetector
        self.yuNetDetector = yuNetDetector
        self.sFaceInference = sFaceInference
    }

    /// Returns one normalized embedding only for a unique, pairable face.
    ///
    /// A zero or multi-face Vision result, a zero or multi-candidate YuNet
    /// result, or a failed strict pair is an intentional `nil`: there is no
    /// unique pairable target. Stage failures are redacted as `.failed`.
    /// Cancellation is preserved exactly and wins a generic failure race.
    func embedding(for frame: CameraFrame) async throws -> FaceEmbedding? {
        do {
            try Task.checkCancellation()

            let visionFaces = try await visionDetector.detect(frame: frame)
            try Task.checkCancellation()
            guard let visionTarget = targetSelector.select(from: visionFaces)
            else {
                try Task.checkCancellation()
                return nil
            }

            let yuNetCandidates = try await yuNetDetector.detect(frame: frame)
            try Task.checkCancellation()

            guard let pairedFace = pairer.pair(
                visionFaces: [visionTarget],
                yuNetCandidates: yuNetCandidates
            ), let landmarks = pairedFace.alignmentLandmarks else {
                try Task.checkCancellation()
                return nil
            }

            try Task.checkCancellation()
            let alignedFace = try cropper.crop(
                frame: frame,
                landmarks: landmarks
            )
            try Task.checkCancellation()

            let embedding = try await sFaceInference.embedding(
                for: alignedFace
            )
            try Task.checkCancellation()
            return embedding
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            // Cancellation wins a race with any generic stage failure.
            if Task.isCancelled {
                throw CancellationError()
            }
            throw SFaceFrameEmbeddingPipelineError.failed
        }
    }
}

// Existing concrete infrastructure components satisfy the narrow seams used
// by this composition. No framework object crosses any of these boundaries.
extension VisionFaceDetector: VisionFaceDetecting {}
extension YuNetFaceCandidatePipeline: YuNetFaceCandidateDetecting {}
extension SFaceCoreMLInference: SFaceEmbeddingInferring {}
