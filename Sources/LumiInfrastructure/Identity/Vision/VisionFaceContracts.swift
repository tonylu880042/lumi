import Foundation

/// The coordinate convention used by Vision observations.
///
/// Both points and rectangles are normalized to the processed image and use a
/// lower-left origin. No UI top-left conversion is performed here.
enum NormalizedCoordinateOrigin: Equatable, Sendable {
    case lowerLeft
}

enum NormalizedGeometryError: Error, Equatable, Sendable {
    case nonFinite
    case outOfRange
    case empty
    case exceedsBounds
}

struct NormalizedPoint: Equatable, Sendable {
    let x: Double
    let y: Double

    var coordinateOrigin: NormalizedCoordinateOrigin { .lowerLeft }

    init(x: Double, y: Double) throws(NormalizedGeometryError) {
        guard x.isFinite, y.isFinite else { throw .nonFinite }
        guard (0...1).contains(x), (0...1).contains(y) else {
            throw .outOfRange
        }
        self.x = x
        self.y = y
    }
}

struct NormalizedRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var coordinateOrigin: NormalizedCoordinateOrigin { .lowerLeft }

    init(
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) throws(NormalizedGeometryError) {
        let values = [x, y, width, height]
        guard values.allSatisfy(\.isFinite) else { throw .nonFinite }
        guard values.allSatisfy({ (0...1).contains($0) }) else {
            throw .outOfRange
        }
        guard width > 0, height > 0 else { throw .empty }
        guard x + width <= 1, y + height <= 1 else {
            throw .exceedsBounds
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

enum DetectedFaceError: Error, Equatable, Sendable {
    case nonFiniteConfidence
    case confidenceOutOfRange
}

/// Framework-neutral face detection output. It carries no target-selection or
/// quality policy; those decisions belong to later layers.
struct DetectedFace: Equatable, Sendable {
    let boundingBox: NormalizedRect
    let confidence: Double
    let alignmentLandmarks: SFaceAlignmentLandmarks?

    init(
        boundingBox: NormalizedRect,
        confidence: Double,
        alignmentLandmarks: SFaceAlignmentLandmarks? = nil
    ) throws(DetectedFaceError) {
        guard confidence.isFinite else { throw .nonFiniteConfidence }
        guard (0...1).contains(confidence) else {
            throw .confidenceOutOfRange
        }
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.alignmentLandmarks = alignmentLandmarks
    }
}

/// The five explicit roles required by the SFace alignment contract.
///
/// Role names are anatomical and subject-relative. Coordinates are measured
/// in the oriented, non-mirrored processed image's normalized lower-left space.
/// The declaration order is OpenCV's `FaceDetectorYN`/`FaceRecognizerSF`
/// alignment order: right eye, left eye, nose tip, right mouth corner, left
/// mouth corner.
enum SFaceAlignmentLandmarkRole: String, CaseIterable, Hashable, Sendable {
    case subjectRightEye
    case subjectLeftEye
    case noseTip
    case subjectRightMouthCorner
    case subjectLeftMouthCorner
}

enum SFaceAlignmentLandmarksError: Error, Equatable, Sendable {
    case missing(SFaceAlignmentLandmarkRole)
}

/// Exact SFace five-point input. A role is never synthesized from a region or
/// inferred by averaging points.
struct SFaceAlignmentLandmarks: Equatable, Sendable {
    private let values: [SFaceAlignmentLandmarkRole: NormalizedPoint]

    init(
        points: [SFaceAlignmentLandmarkRole: NormalizedPoint]
    ) throws(SFaceAlignmentLandmarksError) {
        for role in SFaceAlignmentLandmarkRole.allCases where points[role] == nil {
            throw .missing(role)
        }
        self.values = points
    }

    subscript(role: SFaceAlignmentLandmarkRole) -> NormalizedPoint {
        // Construction validates all five roles before values become visible.
        values[role]!
    }

    /// Points in the exact row order consumed by OpenCV SFace alignment.
    var openCVAlignCropOrder: [NormalizedPoint] {
        [
            self[.subjectRightEye],
            self[.subjectLeftEye],
            self[.noseTip],
            self[.subjectRightMouthCorner],
            self[.subjectLeftMouthCorner]
        ]
    }
}

/// The regions exposed by a future Vision adapter. Region semantics do not
/// imply the exact SFace eye/nose-tip/mouth-corner points.
struct VisionFaceLandmarkRegions: Equatable, Sendable {
    let leftEye: [NormalizedPoint]
    let rightEye: [NormalizedPoint]
    let nose: [NormalizedPoint]
    let outerLips: [NormalizedPoint]
}

enum VisionLandmarkMappingError: Error, Equatable, Sendable {
    case unsupportedLandmarkSemantics
}

/// Explicit boundary for Vision-region to SFace mapping.
///
/// The region API does not expose the SFace five-point semantics directly, so
/// this mapper refuses to guess. Exact point providers construct
/// `SFaceAlignmentLandmarks` directly.
enum VNLandmarkSemanticMapper {
    static func map(
        _ regions: VisionFaceLandmarkRegions
    ) throws(VisionLandmarkMappingError) -> SFaceAlignmentLandmarks {
        _ = regions
        throw .unsupportedLandmarkSemantics
    }
}
