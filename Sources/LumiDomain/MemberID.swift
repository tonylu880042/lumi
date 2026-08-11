/// Stable opaque identity for a Curves member.
public struct MemberID: Equatable, Hashable, Sendable {
    /// The exact string supplied when this value was created.
    public let rawValue: String

    /// Creates an ID from a non-empty raw string without normalizing it.
    public init(rawValue: String) throws(MemberIDError) {
        guard !rawValue.isEmpty else {
            throw MemberIDError.empty
        }
        self.rawValue = rawValue
    }
}

/// Validation failures for a `MemberID` input.
public enum MemberIDError: Error, Equatable, Sendable {
    case empty
}
