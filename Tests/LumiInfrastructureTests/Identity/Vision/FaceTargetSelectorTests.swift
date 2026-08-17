import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("Face target selector")
struct FaceTargetSelectorTests {
    @Test("returns no active target when no faces are detected")
    func returnsNoTargetForNoFaces() {
        let selector = FaceTargetSelector()

        #expect(selector.select(from: []) == nil)
    }

    @Test("preserves the only detected face exactly")
    func preservesSoleFaceExactly() throws {
        let face = try makeFace(
            x: 0.2,
            y: 0.15,
            width: 0.35,
            height: 0.55,
            confidence: 0.42,
            alignmentLandmarks: makeLandmarks()
        )
        let selector = FaceTargetSelector()

        let target = selector.select(from: [face])

        #expect(target == face)
        #expect(target?.alignmentLandmarks == face.alignmentLandmarks)
    }

    @Test("returns no active target for two detected faces")
    func returnsNoTargetForTwoFaces() throws {
        let faces = [
            try makeFace(x: 0.05, y: 0.1, width: 0.2, height: 0.3, confidence: 0.99),
            try makeFace(x: 0.7, y: 0.5, width: 0.25, height: 0.35, confidence: 0.01)
        ]
        let selector = FaceTargetSelector()

        #expect(selector.select(from: faces) == nil)
    }

    @Test("returns no active target for three or more detected faces")
    func returnsNoTargetForThreeOrMoreFaces() throws {
        let faces = [
            try makeFace(x: 0.02, y: 0.08, width: 0.15, height: 0.2, confidence: 0.2),
            try makeFace(x: 0.4, y: 0.25, width: 0.3, height: 0.5, confidence: 1),
            try makeFace(x: 0.75, y: 0.7, width: 0.2, height: 0.25, confidence: 0.8)
        ]
        let selector = FaceTargetSelector()

        #expect(selector.select(from: faces) == nil)
    }

    @Test("multi-face results do not rank by order, confidence, or geometry")
    func multiFaceResultsDoNotRankByOrderConfidenceOrGeometry() throws {
        let leftSmallLowConfidence = try makeFace(
            x: 0.02,
            y: 0.02,
            width: 0.1,
            height: 0.1,
            confidence: 0.01
        )
        let rightLargeHighConfidence = try makeFace(
            x: 0.55,
            y: 0.4,
            width: 0.4,
            height: 0.55,
            confidence: 0.99
        )
        let center = try makeFace(
            x: 0.4,
            y: 0.3,
            width: 0.2,
            height: 0.25,
            confidence: 0.5
        )
        let selector = FaceTargetSelector()

        #expect(selector.select(from: [leftSmallLowConfidence, rightLargeHighConfidence]) == nil)
        #expect(selector.select(from: [rightLargeHighConfidence, leftSmallLowConfidence]) == nil)
        #expect(selector.select(from: [center, rightLargeHighConfidence, leftSmallLowConfidence]) == nil)
    }

    @Test("selector and selected target are Sendable values")
    func selectorAndTargetAreSendable() throws {
        let face = try makeFace(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.4,
            confidence: 0.75
        )
        let selector = FaceTargetSelector()
        let target = selector.select(from: [face])

        acceptsSendable(selector)
        acceptsSendable(target)
    }

    private func makeFace(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        confidence: Double,
        alignmentLandmarks: SFaceAlignmentLandmarks? = nil
    ) throws -> DetectedFace {
        try DetectedFace(
            boundingBox: NormalizedRect(
                x: x,
                y: y,
                width: width,
                height: height
            ),
            confidence: confidence,
            alignmentLandmarks: alignmentLandmarks
        )
    }

    private func makeLandmarks() throws -> SFaceAlignmentLandmarks {
        try SFaceAlignmentLandmarks(points: [
            .subjectRightEye: try NormalizedPoint(x: 0.3, y: 0.7),
            .subjectLeftEye: try NormalizedPoint(x: 0.7, y: 0.7),
            .noseTip: try NormalizedPoint(x: 0.5, y: 0.52),
            .subjectRightMouthCorner: try NormalizedPoint(x: 0.35, y: 0.3),
            .subjectLeftMouthCorner: try NormalizedPoint(x: 0.65, y: 0.3)
        ])
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
