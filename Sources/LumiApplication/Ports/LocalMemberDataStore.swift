import Foundation
import LumiDomain

/// Local-first storage boundary for member profiles and visit history.
///
/// Identity embeddings intentionally do not cross this Application port. They
/// remain owned by the Infrastructure identity subsystem and are versioned
/// there when the SFace adapter is introduced.
public protocol LocalMemberDataStore: Sendable {
    func saveMember(_ member: Member) async throws
    func member(for id: MemberID) async throws -> Member?
    func recordVisit(memberID: MemberID, at arrival: Date) async throws
    func visitSummary(for memberID: MemberID, since startDate: Date) async throws -> MemberVisitSummary
}
