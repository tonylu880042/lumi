/// Privacy-safe aggregate for the locally enrolled identity gallery.
///
/// Implementations count distinct identity keys. Face samples, embeddings,
/// spoken labels, and recognition scores never cross this boundary.
public protocol IdentityEnrollmentSummaryPort: Sendable {
    func enrolledMemberCount() async throws -> Int
}
