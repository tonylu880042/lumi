import Foundation

/// Stable, payload-free failure for the YuNet face-candidate path.
enum YuNetFaceCandidatePipelineError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case failed

    var description: String { "YuNet face candidate pipeline failed." }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}

/// Composes YuNet's framework-neutral preprocessing, inference, postprocessing,
/// and letterbox de-mapping into original-frame face candidates. Vision remains
/// authoritative for frame-level rectangles; callers must pair these candidates
/// with Vision observations later. This type does not select a face or replace
/// Vision's authoritative detection.
struct YuNetFaceCandidatePipeline: Sendable {
    private let preprocessor: YuNetVImagePreprocessor
    private let inference: YuNetCoreMLRawInference
    private let postprocessor: YuNetPostprocessor

    init(
        inference: YuNetCoreMLRawInference,
        postprocessor: YuNetPostprocessor
    ) {
        self.preprocessor = YuNetVImagePreprocessor()
        self.inference = inference
        self.postprocessor = postprocessor
    }

    /// Produces YuNet face candidates in an owned upright frame's original
    /// lower-left normalized coordinate space. The returned `[DetectedFace]`
    /// values are not authoritative identity targets: callers must pair them
    /// with Vision observations later, and this type never selects a face or
    /// replaces Vision's authoritative frame-level detection.
    ///
    /// Any malformed face geometry, missing landmark set, or padding overlap
    /// fails the complete frame. A caller cancellation is preserved exactly;
    /// it also wins if a generic stage failure races with cancellation.
    func detect(frame: CameraFrame) async throws -> [DetectedFace] {
        do {
            try Task.checkCancellation()
            let input = try preprocessor.preprocess(frame: frame)
            try Task.checkCancellation()

            let rawTensors = try await inference.predict(input)
            try Task.checkCancellation()

            let processedFaces = try postprocessor.process(rawTensors)
            try Task.checkCancellation()

            var mappedFaces: [DetectedFace] = []
            mappedFaces.reserveCapacity(processedFaces.count)
            for face in processedFaces {
                try Task.checkCancellation()
                guard let landmarks = face.alignmentLandmarks else {
                    throw YuNetFaceCandidatePipelineError.failed
                }

                let mappedBoundingBox = try input.transform.unmap(
                    rect: face.boundingBox
                )
                var mappedPoints: [SFaceAlignmentLandmarkRole: NormalizedPoint] = [:]
                mappedPoints.reserveCapacity(SFaceAlignmentLandmarkRole.allCases.count)
                for role in SFaceAlignmentLandmarkRole.allCases {
                    mappedPoints[role] = try input.transform.unmap(
                        point: landmarks[role]
                    )
                }
                let mappedLandmarks = try SFaceAlignmentLandmarks(
                    points: mappedPoints
                )
                mappedFaces.append(try DetectedFace(
                    boundingBox: mappedBoundingBox,
                    confidence: face.confidence,
                    alignmentLandmarks: mappedLandmarks
                ))
            }
            try Task.checkCancellation()
            return mappedFaces
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw YuNetFaceCandidatePipelineError.failed
        }
    }
}
