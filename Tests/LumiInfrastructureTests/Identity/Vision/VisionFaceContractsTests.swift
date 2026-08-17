import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("Vision face contracts")
struct VisionFaceContractsTests {
    @Test("normalised points use finite lower-left coordinates")
    func normalisedPointIsValidated() throws {
        let point = try NormalizedPoint(x: 0.25, y: 0.75)

        #expect(point.x == 0.25)
        #expect(point.y == 0.75)
        #expect(point.coordinateOrigin == .lowerLeft)
    }

    @Test("normalised points reject non-finite and out-of-range values")
    func normalisedPointRejectsInvalidValues() {
        #expect(throws: NormalizedGeometryError.nonFinite) {
            try NormalizedPoint(x: .infinity, y: 0.5)
        }
        #expect(throws: NormalizedGeometryError.outOfRange) {
            try NormalizedPoint(x: -0.01, y: 0.5)
        }
        #expect(throws: NormalizedGeometryError.outOfRange) {
            try NormalizedPoint(x: 0.5, y: 1.01)
        }
    }

    @Test("normalised rectangles stay within the image")
    func normalisedRectIsValidated() throws {
        let rect = try NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)

        #expect(rect.coordinateOrigin == .lowerLeft)
        #expect(rect.maxX == 0.6)
        #expect(rect.maxY == 0.8)
    }

    @Test("normalised rectangles reject overflow")
    func normalisedRectRejectsOverflow() {
        #expect(throws: NormalizedGeometryError.exceedsBounds) {
            try NormalizedRect(x: 0.75, y: 0.1, width: 0.5, height: 0.2)
        }
        #expect(throws: NormalizedGeometryError.outOfRange) {
            try NormalizedRect(x: 0.1, y: 0.1, width: -0.1, height: 0.2)
        }
        #expect(throws: NormalizedGeometryError.empty) {
            try NormalizedRect(x: 0.1, y: 0.1, width: 0, height: 0.2)
        }
        #expect(throws: NormalizedGeometryError.empty) {
            try NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0)
        }
    }

    @Test("detected face carries only pure values and no selection policy")
    func detectedFaceIsSendableValue() throws {
        let face = try DetectedFace(
            boundingBox: NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6),
            confidence: 0.8
        )

        #expect(face.confidence == 0.8)
        #expect(face.alignmentLandmarks == nil)
        acceptsSendable(face)
    }

    @Test("exact five SFace roles can be constructed from exact points")
    func exactSFaceRolesConstruct() throws {
        let landmarks = try SFaceAlignmentLandmarks(points: exactPoints())
        let subjectRightEye = try NormalizedPoint(x: 0.2, y: 0.7)
        let subjectLeftEye = try NormalizedPoint(x: 0.8, y: 0.7)
        let noseTip = try NormalizedPoint(x: 0.5, y: 0.5)
        let subjectRightMouthCorner = try NormalizedPoint(x: 0.3, y: 0.3)
        let subjectLeftMouthCorner = try NormalizedPoint(x: 0.7, y: 0.3)

        #expect(landmarks[.subjectRightEye] == subjectRightEye)
        #expect(landmarks[.subjectLeftEye] == subjectLeftEye)
        #expect(landmarks[.noseTip] == noseTip)
        #expect(landmarks[.subjectRightMouthCorner] == subjectRightMouthCorner)
        #expect(landmarks[.subjectLeftMouthCorner] == subjectLeftMouthCorner)
        #expect(landmarks.openCVAlignCropOrder == [
            subjectRightEye,
            subjectLeftEye,
            noseTip,
            subjectRightMouthCorner,
            subjectLeftMouthCorner
        ])
        acceptsSendable(landmarks)
    }

    @Test("subject roles use oriented non-mirrored image coordinates")
    func subjectRoleCoordinatesAreAnatomical() throws {
        // In an oriented, non-mirrored frontal image, subject-right landmarks
        // appear at smaller image x than subject-left landmarks.
        let points = try exactPoints()

        #expect(points[.subjectRightEye]!.x < points[.subjectLeftEye]!.x)
        #expect(
            points[.subjectRightMouthCorner]!.x
                < points[.subjectLeftMouthCorner]!.x
        )
    }

    @Test("missing exact SFace roles are typed")
    func missingSFaceRoleFails() {
        var points = try! exactPoints()
        points.removeValue(forKey: .noseTip)

        #expect(throws: SFaceAlignmentLandmarksError.missing(.noseTip)) {
            try SFaceAlignmentLandmarks(points: points)
        }
    }

    @Test("Vision region semantics do not guess SFace points")
    func visionSemanticMapperReportsUnsupportedSemantics() throws {
        let regions = VisionFaceLandmarkRegions(
            leftEye: [try NormalizedPoint(x: 0.2, y: 0.7)],
            rightEye: [try NormalizedPoint(x: 0.8, y: 0.7)],
            nose: [try NormalizedPoint(x: 0.5, y: 0.5)],
            outerLips: [
                try NormalizedPoint(x: 0.3, y: 0.3),
                try NormalizedPoint(x: 0.7, y: 0.3)
            ]
        )

        #expect(throws: VisionLandmarkMappingError.unsupportedLandmarkSemantics) {
            try VNLandmarkSemanticMapper.map(regions)
        }
    }

    private func exactPoints() throws -> [SFaceAlignmentLandmarkRole: NormalizedPoint] {
        [
            .subjectRightEye: try NormalizedPoint(x: 0.2, y: 0.7),
            .subjectLeftEye: try NormalizedPoint(x: 0.8, y: 0.7),
            .noseTip: try NormalizedPoint(x: 0.5, y: 0.5),
            .subjectRightMouthCorner: try NormalizedPoint(x: 0.3, y: 0.3),
            .subjectLeftMouthCorner: try NormalizedPoint(x: 0.7, y: 0.3)
        ]
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
