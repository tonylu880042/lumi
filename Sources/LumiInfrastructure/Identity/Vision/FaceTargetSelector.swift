/// Selects the active face target only when detection produced one face.
///
/// A zero-face or multi-face result is intentionally fail-closed. Geometry,
/// detector confidence, and ordering do not participate in target selection.
struct FaceTargetSelector: Sendable {
    func select(from faces: [DetectedFace]) -> DetectedFace? {
        guard faces.count == 1 else { return nil }
        return faces[0]
    }
}
