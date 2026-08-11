import LumiDomain

/// Application boundary for member profile and weekly exercise data.
public protocol MemberRepository: Sendable {
    /// Returns the Domain member profile for the exact requested ID.
    func profile(for id: MemberID) async throws -> Member

    /// Returns the Domain exercise summary for the exact requested ID.
    func weeklySummary(for id: MemberID) async throws -> ExerciseSummary
}
