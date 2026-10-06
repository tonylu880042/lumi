import Foundation

/// A face rectangle expressed in the processed frame's pixel dimensions.
///
/// Coordinates use the same lower-left origin as `NormalizedRect`. Keeping
/// the coordinate convention identical makes the pixel and normalized values
/// directly comparable while leaving any UI top-left conversion to a later
/// presentation boundary. This value contains geometry only; it never carries
/// an identity, image, confidence score, or embedding.
struct FacePixelRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var area: Double { width * height }
    var coordinateOrigin: NormalizedCoordinateOrigin { .lowerLeft }
}

/// Anonymous, numeric geometry for exactly one detected face in one frame.
///
/// The source frame dimensions are retained so recorded measurements can be
/// interpreted without any image payload. No distance or near/far policy is
/// applied here; a later, calibrated policy may consume the dimensions and
/// face sizes.
struct FaceGeometryObservation: Equatable, Sendable {
    let frameWidth: Int
    let frameHeight: Int
    let normalizedBoundingBox: NormalizedRect
    let pixelBoundingBox: FacePixelRect
    let pose: FacePoseObservation?

    var normalizedArea: Double {
        normalizedBoundingBox.width * normalizedBoundingBox.height
    }

    var pixelArea: Double {
        pixelBoundingBox.area
    }

    init(frame: CameraFrame, face: DetectedFace) {
        let normalized = face.boundingBox
        let frameWidth = Double(frame.width)
        let frameHeight = Double(frame.height)

        self.frameWidth = frame.width
        self.frameHeight = frame.height
        self.normalizedBoundingBox = normalized
        self.pixelBoundingBox = FacePixelRect(
            x: normalized.x * frameWidth,
            y: normalized.y * frameHeight,
            width: normalized.width * frameWidth,
            height: normalized.height * frameHeight
        )
        self.pose = face.pose
    }
}

/// Observes one frame's anonymous face geometry without selecting an identity.
///
/// A frame with no face or multiple faces returns `nil`. The observer performs
/// no ranking, face-size thresholding, orientation inference, gallery lookup,
/// or identity recognition. Detector errors remain errors and cancellation is
/// preserved by the underlying Vision boundary.
struct FaceGeometryObserver: Sendable {
    private let detector: VisionFaceDetector

    init(detector: VisionFaceDetector) {
        self.detector = detector
    }

    func observe(frame: CameraFrame) async throws -> FaceGeometryObservation? {
        try Task.checkCancellation()
        let faces = try await detector.detect(frame: frame)
        try Task.checkCancellation()

        guard let face = FaceTargetSelector().select(from: faces) else {
            return nil
        }

        return FaceGeometryObservation(frame: frame, face: face)
    }
}
