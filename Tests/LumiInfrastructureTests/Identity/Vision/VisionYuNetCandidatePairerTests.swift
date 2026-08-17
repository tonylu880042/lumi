import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("Vision and YuNet candidate pairer")
struct VisionYuNetCandidatePairerTests {
    @Test("uses Vision bbox and confidence with YuNet landmarks")
    func combinesAuthoritativeVisionGeometry() throws {
        let visionLandmarks = try makeLandmarks(seed: 0)
        let yuNetLandmarks = try makeLandmarks(seed: 0.01)
        let vision = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.62,
            landmarks: visionLandmarks
        )
        let candidate = try makeFace(
            rect: try makeRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            confidence: 0.98,
            landmarks: yuNetLandmarks
        )

        let paired = VisionYuNetCandidatePairer().pair(
            visionFaces: [vision],
            yuNetCandidates: [candidate]
        )

        #expect(paired?.boundingBox == vision.boundingBox)
        #expect(paired?.confidence == vision.confidence)
        #expect(paired?.alignmentLandmarks == yuNetLandmarks)
        #expect(paired?.alignmentLandmarks != visionLandmarks)
        #expect(paired?.alignmentLandmarks?.openCVAlignCropOrder.count == 5)
    }

    @Test("requires exactly one Vision face and one YuNet candidate")
    func rejectsZeroOrMultipleInputs() throws {
        let vision = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.7,
            landmarks: try makeLandmarks(seed: 0)
        )
        let candidate = try makeFace(
            rect: try makeRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            confidence: 0.9,
            landmarks: try makeLandmarks(seed: 0.01)
        )
        let pairer = VisionYuNetCandidatePairer()

        #expect(pairer.pair(visionFaces: [], yuNetCandidates: [candidate]) == nil)
        #expect(pairer.pair(visionFaces: [vision], yuNetCandidates: []) == nil)
        #expect(
            pairer.pair(
                visionFaces: [vision, vision],
                yuNetCandidates: [candidate]
            ) == nil
        )
        #expect(
            pairer.pair(
                visionFaces: [vision],
                yuNetCandidates: [candidate, candidate]
            ) == nil
        )
    }

    @Test("requires strict center containment in both directions")
    func rejectsOneWayContainment() throws {
        let pairer = VisionYuNetCandidatePairer()
        let visionCenterInsideCandidate = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2),
            confidence: 0.7,
            landmarks: try makeLandmarks(seed: 0)
        )
        let candidateCenterOutsideVision = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
            confidence: 0.9,
            landmarks: try makeLandmarks(seed: 0.01)
        )
        #expect(
            pairer.pair(
                visionFaces: [visionCenterInsideCandidate],
                yuNetCandidates: [candidateCenterOutsideVision]
            ) == nil
        )

        let visionCenterOutsideCandidate = candidateCenterOutsideVision
        let candidateCenterInsideVision = visionCenterInsideCandidate
        #expect(
            pairer.pair(
                visionFaces: [visionCenterOutsideCandidate],
                yuNetCandidates: [candidateCenterInsideVision]
            ) == nil
        )
    }

    @Test("rejects all exact x and y center-boundary cases")
    func rejectsCenterOnAnyBoundary() throws {
        let vision = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.7,
            landmarks: try makeLandmarks(seed: 0)
        )
        let boundaryRects = [
            try makeRect(x: 0.5, y: 0.4, width: 0.2, height: 0.2), // x min
            try makeRect(x: 0.3, y: 0.4, width: 0.2, height: 0.2), // x max
            try makeRect(x: 0.4, y: 0.5, width: 0.2, height: 0.2), // y min
            try makeRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2)  // y max
        ]
        let pairer = VisionYuNetCandidatePairer()

        for rect in boundaryRects {
            let candidate = try makeFace(
                rect: rect,
                confidence: 0.9,
                landmarks: try makeLandmarks(seed: 0.01)
            )
            #expect(
                pairer.pair(
                    visionFaces: [vision],
                    yuNetCandidates: [candidate]
                ) == nil
            )
        }
    }

    @Test("accepts a near-inside center without an epsilon")
    func acceptsNearInsideCenter() throws {
        let vision = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.7,
            landmarks: try makeLandmarks(seed: 0)
        )
        let candidate = try makeFace(
            rect: try makeRect(
                x: 0.5 - 1e-12,
                y: 0.5 - 1e-12,
                width: 0.2,
                height: 0.2
            ),
            confidence: 0.9,
            landmarks: try makeLandmarks(seed: 0.01)
        )

        #expect(
            VisionYuNetCandidatePairer().pair(
                visionFaces: [vision],
                yuNetCandidates: [candidate]
            ) != nil
        )
    }

    @Test("rejects a YuNet candidate without five landmarks")
    func rejectsMissingCandidateLandmarks() throws {
        let vision = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.7,
            landmarks: try makeLandmarks(seed: 0)
        )
        let candidate = try makeFace(
            rect: try makeRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            confidence: 0.9,
            landmarks: nil
        )

        #expect(
            VisionYuNetCandidatePairer().pair(
                visionFaces: [vision],
                yuNetCandidates: [candidate]
            ) == nil
        )
    }

    @Test("does not rank or override the exact-one rule")
    func ignoresOrderAndConfidenceWhenCountsAreInvalid() throws {
        let highConfidenceVision = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 1,
            landmarks: try makeLandmarks(seed: 0)
        )
        let lowConfidenceVision = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.01,
            landmarks: try makeLandmarks(seed: 0.02)
        )
        let candidate = try makeFace(
            rect: try makeRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            confidence: 0.99,
            landmarks: try makeLandmarks(seed: 0.01)
        )

        #expect(
            VisionYuNetCandidatePairer().pair(
                visionFaces: [lowConfidenceVision, highConfidenceVision],
                yuNetCandidates: [candidate]
            ) == nil
        )
    }

    @Test("keeps the stateless pairer Sendable")
    func pairerIsSendable() {
        acceptsSendable(VisionYuNetCandidatePairer())
    }

    private func makeFace(
        rect: NormalizedRect,
        confidence: Double,
        landmarks: SFaceAlignmentLandmarks?
    ) throws -> DetectedFace {
        try DetectedFace(
            boundingBox: rect,
            confidence: confidence,
            alignmentLandmarks: landmarks
        )
    }

    private func makeRect(
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) throws -> NormalizedRect {
        try NormalizedRect(x: x, y: y, width: width, height: height)
    }

    private func makeLandmarks(seed: Double) throws -> SFaceAlignmentLandmarks {
        let coordinates: [
            (SFaceAlignmentLandmarkRole, Double, Double)
        ] = [
            (.subjectRightEye, 0.1 + seed, 0.2 + seed),
            (.subjectLeftEye, 0.2 + seed, 0.3 + seed),
            (.noseTip, 0.3 + seed, 0.4 + seed),
            (.subjectRightMouthCorner, 0.4 + seed, 0.5 + seed),
            (.subjectLeftMouthCorner, 0.5 + seed, 0.6 + seed)
        ]
        var points: [SFaceAlignmentLandmarkRole: NormalizedPoint] = [:]
        for (role, x, y) in coordinates {
            points[role] = try NormalizedPoint(x: x, y: y)
        }
        return try SFaceAlignmentLandmarks(points: points)
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
