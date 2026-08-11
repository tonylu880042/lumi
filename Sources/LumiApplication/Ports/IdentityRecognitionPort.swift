import LumiDomain

/// Application boundary for resolving the person currently in front of Lumi.
///
/// The port exposes only the semantic public result. Low-level recognition
/// policy reasons stay inside the Domain/Application layers.
public protocol IdentityRecognitionPort: Sendable {
    func recognizeCurrentVisitor() async throws -> RecognitionResult
}
