import Foundation
import LumiDomain

/// Independent consent for the local interaction-memory feature.
public enum MemberMemoryConsentStatus: Equatable, Sendable {
    case disabled
    case enabled(consentedAt: Date)
}

/// A revisioned read used to prevent a clear/disable operation from being
/// undone by a late session callback.
public struct MemberMemoryEventBatch: Equatable, Sendable {
    public let events: [MemberMemoryEvent]
    public let revision: UInt64

    public init(events: [MemberMemoryEvent], revision: UInt64) {
        self.events = events
        self.revision = revision
    }
}

/// The result of one revision-guarded write. The returned revision lets one
/// active session continue with a second independent write (for example, a
/// completed meeting followed by a same-session exercise disclosure).
public struct MemberMemoryAppendResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case appended
        case duplicate
        case rejected
        case ignored
    }

    public let outcome: Outcome
    public let revision: UInt64

    public init(outcome: Outcome, revision: UInt64) {
        self.outcome = outcome
        self.revision = revision
    }

    public var wasAccepted: Bool {
        outcome == .appended || outcome == .duplicate
    }
}

/// Result of correcting the one persistent exercise disclosure allowed by the
/// pilot. A correction removes the current-day structured fact; it never
/// appends free-form history or rewrites an official workout record.
public struct MemberMemoryCorrectionResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case corrected
        case notFound
        case rejected
    }

    public let outcome: Outcome
    public let revision: UInt64

    public init(outcome: Outcome, revision: UInt64) {
        self.outcome = outcome
        self.revision = revision
    }
}

/// An identity projection owned by the local identity boundary. The value is
/// deliberately limited to the local opaque ID and the member's volunteered
/// spoken label; it contains no face data or memory events.
public struct MemberMemoryProfile: Equatable, Sendable {
    public let memberID: MemberID
    public let spokenLabel: String

    public init(memberID: MemberID, spokenLabel: String) {
        self.memberID = memberID
        self.spokenLabel = spokenLabel
    }
}

/// Read-only identity projection used by the operator memory-management
/// surface. Infrastructure implements this from its actual local profile
/// table; the memory database never joins or guesses identity data.
public protocol MemberMemoryProfileDirectory: Sendable {
    func memberMemoryProfiles() async throws -> [MemberMemoryProfile]
}

/// The minimum member directory data needed by the local management surface.
/// The opaque ID remains local and is never sent to the voice provider.
public struct MemberMemoryManagementProfile: Equatable, Sendable {
    public let memberID: MemberID
    public let spokenLabel: String
    public let consent: MemberMemoryConsentStatus

    public init(
        memberID: MemberID,
        spokenLabel: String,
        consent: MemberMemoryConsentStatus
    ) {
        self.memberID = memberID
        self.spokenLabel = spokenLabel
        self.consent = consent
    }
}

/// Local persistence boundary for member interaction memory.
public protocol MemberInteractionMemoryStore: Sendable {
    func consentStatus(for memberID: MemberID) async throws -> MemberMemoryConsentStatus

    func loadBatch(
        for memberID: MemberID,
        at now: Date
    ) async throws -> MemberMemoryEventBatch

    /// Returns a new revision on both successful and duplicate writes. A
    /// rejected write carries the current revision when it is available.
    func append(
        _ event: MemberMemoryEvent,
        for memberID: MemberID,
        expectedRevision: UInt64
    ) async throws -> MemberMemoryAppendResult

    /// Removes a same-day `completedToday` disclosure under the loaded
    /// revision. Session-only states are held in Application memory and never
    /// reach this persistence operation.
    func correctExerciseDisclosure(
        for memberID: MemberID,
        at now: Date,
        expectedRevision: UInt64
    ) async throws -> MemberMemoryCorrectionResult

    func setConsent(
        for memberID: MemberID,
        status: MemberMemoryConsentStatus
    ) async throws

    /// Clears only interaction-memory records and leaves identity records intact.
    func clearMemory(for memberID: MemberID) async throws

    /// Startup maintenance prunes expired structured events for every member
    /// and advances affected revisions. Implementations that do not persist
    /// memory may use the default no-op.
    func pruneExpired(at now: Date) async throws
}

public extension MemberInteractionMemoryStore {
    func correctExerciseDisclosure(
        for _: MemberID,
        at _: Date,
        expectedRevision: UInt64
    ) async throws -> MemberMemoryCorrectionResult {
        MemberMemoryCorrectionResult(
            outcome: .rejected,
            revision: expectedRevision
        )
    }

    func pruneExpired(at _: Date) async throws {}
}
