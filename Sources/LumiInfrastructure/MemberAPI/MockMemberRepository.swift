import LumiApplication
import LumiDomain

/// A deterministic, in-memory member record used by tests and explicit
/// development composition only. It has no built-in member data.
public struct MockMemberRecord: Equatable, Sendable {
    public let member: Member
    public let weeklySummary: ExerciseSummary

    public init(member: Member, weeklySummary: ExerciseSummary) {
        self.member = member
        self.weeklySummary = weeklySummary
    }
}

/// Payload-free failures for the deterministic mock repository.
public enum MockMemberRepositoryError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case memberNotFound
    case duplicateMember

    public var description: String {
        switch self {
        case .memberNotFound:
            "memberNotFound"
        case .duplicateMember:
            "duplicateMember"
        }
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, unlabeledChildren: [], displayStyle: .enum)
    }
}

/// A deterministic in-memory implementation of the member data boundary.
///
/// Records are supplied by the composition root; this type never invents
/// dates, random values, or default member data.
public actor MockMemberRepository: MemberRepository {
    private let recordsByID: [MemberID: MockMemberRecord]

    public init(
        records: [MockMemberRecord]
    ) throws(MockMemberRepositoryError) {
        var recordsByID: [MemberID: MockMemberRecord] = [:]
        recordsByID.reserveCapacity(records.count)

        for record in records {
            guard recordsByID.updateValue(record, forKey: record.member.id) == nil else {
                throw .duplicateMember
            }
        }

        self.recordsByID = recordsByID
    }

    public func profile(for id: MemberID) async throws -> Member {
        guard let record = recordsByID[id] else {
            throw MockMemberRepositoryError.memberNotFound
        }
        return record.member
    }

    public func weeklySummary(for id: MemberID) async throws -> ExerciseSummary {
        guard let record = recordsByID[id] else {
            throw MockMemberRepositoryError.memberNotFound
        }
        return record.weeklySummary
    }
}
