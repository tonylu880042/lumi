/// A Curves member profile used by the Domain layer.
public struct Member: Equatable, Sendable {
    /// The member's stable identity.
    public let id: MemberID

    /// The name presented for the member.
    public let displayName: String

    /// Creates a member profile.
    public init(id: MemberID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}
