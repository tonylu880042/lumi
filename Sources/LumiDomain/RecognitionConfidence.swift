/// A validated confidence score in the inclusive range 0...1.
public struct RecognitionConfidence: Equatable, Comparable, Sendable {
    public let value: Double

    /// Creates a confidence score without clamping or otherwise changing it.
    public init(value: Double) throws(RecognitionConfidenceError) {
        guard value.isFinite else {
            throw RecognitionConfidenceError.nonFinite
        }
        guard (0.0...1.0).contains(value) else {
            throw RecognitionConfidenceError.outOfRange(value: value)
        }
        self.value = value
    }

    public static func < (
        lhs: RecognitionConfidence,
        rhs: RecognitionConfidence
    ) -> Bool {
        lhs.value < rhs.value
    }
}

/// Validation failures for a `RecognitionConfidence` input.
public enum RecognitionConfidenceError: Error, Equatable, Sendable {
    case nonFinite
    case outOfRange(value: Double)
}
