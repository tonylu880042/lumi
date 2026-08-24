import Foundation
import LumiDomain

/// Result of one explicitly consented automatic enrollment capture.
public enum VisitorEnrollmentBeginResult: Equatable, Sendable {
    /// Exactly this many usable embeddings are pending in memory.
    case samplesCaptured(Int)
    case noUsableFace
}

/// Provider-independent boundary for the local conversational enrollment.
///
/// `begin` must keep samples in memory. `complete` atomically persists them
/// under the supplied generated member ID and spoken address. `cancel` must
/// stop capture and discard every pending sample without persistence.
public protocol VisitorEnrollmentPort: Sendable {
    func begin(consentedAt: Date) async throws -> VisitorEnrollmentBeginResult

    func complete(
        memberID: MemberID,
        address: VoiceMemberAddress,
        completedAt: Date
    ) async throws

    func cancel() async
}

/// Local lookup for a voluntarily supplied spoken address.
///
/// The generated `MemberID` remains the identity key. Implementations return
/// only the validated label needed for local UI and voice greeting.
public protocol VoiceMemberAddressRepository: Sendable {
    func address(for memberID: MemberID) async throws -> VoiceMemberAddress?
}
