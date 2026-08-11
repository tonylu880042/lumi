/// A validated motor target, expressed in degrees relative to Home (0°).
public struct RotationAngle: Equatable, Sendable {
    public let degrees: Double

    public init(degrees: Double) throws(RotationAngleError) {
        guard degrees.isFinite else {
            throw RotationAngleError.nonFinite
        }
        guard (-90.0...90.0).contains(degrees) else {
            throw RotationAngleError.outOfRange(degrees: degrees)
        }
        self.degrees = degrees
    }
}

/// Validation failures for a `RotationAngle` input.
public enum RotationAngleError: Error, Equatable, Sendable {
    case nonFinite
    case outOfRange(degrees: Double)
}
