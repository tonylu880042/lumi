/// The public semantic outcome of identity recognition.
///
/// Policy diagnostics such as an unknown reason remain outside this boundary.
public enum RecognitionResult: Equatable, Sendable {
    case known(memberID: MemberID, confidence: RecognitionConfidence)
    case unknown
}
