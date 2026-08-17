import Foundation

/// Pairs one authoritative Vision face rectangle with one YuNet candidate.
///
/// This boundary performs no ranking or identity selection. It only accepts
/// strict two-way center containment and carries YuNet's exact five-point
/// landmarks onto Vision's authoritative geometry and confidence.
struct VisionYuNetCandidatePairer: Sendable {
    init() {}

    func pair(
        visionFaces: [DetectedFace],
        yuNetCandidates: [DetectedFace]
    ) -> DetectedFace? {
        guard visionFaces.count == 1, yuNetCandidates.count == 1,
              let vision = visionFaces.first,
              let candidate = yuNetCandidates.first,
              let yuNetLandmarks = candidate.alignmentLandmarks else {
            return nil
        }

        let visionCenter = center(of: vision.boundingBox)
        let yuNetCenter = center(of: candidate.boundingBox)
        guard strictlyContains(visionCenter, in: candidate.boundingBox),
              strictlyContains(yuNetCenter, in: vision.boundingBox) else {
            return nil
        }

        do {
            // SFaceAlignmentLandmarks construction already guarantees all five
            // explicit roles; preserve that typed value without re-synthesis.
            return try DetectedFace(
                boundingBox: vision.boundingBox,
                confidence: vision.confidence,
                alignmentLandmarks: yuNetLandmarks
            )
        } catch {
            return nil
        }
    }

    private func center(of rect: NormalizedRect) -> (x: Double, y: Double) {
        (
            x: rect.x + rect.width / 2,
            y: rect.y + rect.height / 2
        )
    }

    private func strictlyContains(
        _ point: (x: Double, y: Double),
        in rect: NormalizedRect
    ) -> Bool {
        point.x > rect.x
            && point.x < rect.maxX
            && point.y > rect.y
            && point.y < rect.maxY
    }
}
