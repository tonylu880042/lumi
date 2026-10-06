import Foundation
import LumiDomain

/// Fixed failures for malformed inputs at the Application memory boundary.
public enum MemberMemoryUseCaseError: Error, Equatable, Sendable {
    case invalidSessionID
    case invalidInteractionID
    case invalidDate
}

/// Result of loading one member's independent, consent-gated memory context.
public enum MemberMemoryLoadResult: Equatable, Sendable {
    case disabled
    case available(MemberMemorySessionContext)
}

public struct MemberMemorySessionContext: Equatable, Sendable {
    public let snapshot: MemberMemorySnapshot
    public let revision: UInt64

    public init(snapshot: MemberMemorySnapshot, revision: UInt64) {
        self.snapshot = snapshot
        self.revision = revision
    }
}

/// Loads historical facts before the current meeting is recorded.
public struct LoadMemberMemoryUseCase: Sendable {
    private let store: any MemberInteractionMemoryStore
    private let policy: MemberInteractionMemoryPolicy

    public init(
        store: any MemberInteractionMemoryStore,
        policy: MemberInteractionMemoryPolicy = MemberInteractionMemoryPolicy()
    ) {
        self.store = store
        self.policy = policy
    }

    public func execute(
        for memberID: MemberID,
        at now: Date
    ) async throws -> MemberMemoryLoadResult {
        try Task.checkCancellation()
        switch try await store.consentStatus(for: memberID) {
        case .disabled:
            return .disabled
        case .enabled:
            let batch = try await store.loadBatch(for: memberID, at: now)
            try Task.checkCancellation()
            let snapshot = policy.snapshot(
                from: batch.events,
                at: now,
                timeZone: MemberInteractionMemoryPolicy.storeTimeZone
            )
            return .available(
                MemberMemorySessionContext(
                    snapshot: snapshot,
                    revision: batch.revision
                )
            )
        }
    }
}

/// Writes one completed known-member meeting after the greeting completes.
public struct RecordMemberMeetingUseCase: Sendable {
    private let store: any MemberInteractionMemoryStore

    public init(store: any MemberInteractionMemoryStore) {
        self.store = store
    }

    public func execute(
        for memberID: MemberID,
        sessionID: String,
        at recordedAt: Date,
        expectedRevision: UInt64
    ) async throws -> MemberMemoryAppendResult {
        guard !sessionID.isEmpty else {
            throw MemberMemoryUseCaseError.invalidSessionID
        }
        guard recordedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MemberMemoryUseCaseError.invalidDate
        }

        let event = MemberMemoryEvent(
            eventID: "meeting:\(sessionID)",
            interactionID: sessionID,
            kind: .meeting,
            source: .lumiObserved,
            recordedAt: recordedAt,
            exerciseDisclosure: nil
        )
        try Task.checkCancellation()
        return try await store.append(
            event,
            for: memberID,
            expectedRevision: expectedRevision
        )
    }
}

/// Writes the only persistent exercise disclosure: an explicit statement that
/// the member completed exercise today. Session-only disclosures stay in the
/// active coordinator context.
public struct RecordMemberExerciseDisclosureUseCase: Sendable {
    private let store: any MemberInteractionMemoryStore

    public init(store: any MemberInteractionMemoryStore) {
        self.store = store
    }

    public func execute(
        for memberID: MemberID,
        disclosure: MemberExerciseDisclosure,
        interactionID: String,
        at recordedAt: Date,
        expectedRevision: UInt64
    ) async throws -> MemberMemoryAppendResult {
        guard !interactionID.isEmpty else {
            throw MemberMemoryUseCaseError.invalidInteractionID
        }
        guard recordedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MemberMemoryUseCaseError.invalidDate
        }
        guard disclosure.isPersistent else {
            return MemberMemoryAppendResult(
                outcome: .ignored,
                revision: expectedRevision
            )
        }

        let event = MemberMemoryEvent(
            eventID: "exercise:\(interactionID)",
            interactionID: interactionID,
            kind: .exerciseDisclosure,
            source: .memberReported,
            recordedAt: recordedAt,
            exerciseDisclosure: disclosure
        )
        try Task.checkCancellation()
        return try await store.append(
            event,
            for: memberID,
            expectedRevision: expectedRevision
        )
    }
}

/// Removes a previously persisted current-day completion after the member
/// clearly corrects or retracts it. The store enforces the session revision
/// and day boundary; this use case owns only input validation and cancellation.
public struct CorrectMemberExerciseDisclosureUseCase: Sendable {
    private let store: any MemberInteractionMemoryStore

    public init(store: any MemberInteractionMemoryStore) {
        self.store = store
    }

    public func execute(
        for memberID: MemberID,
        at now: Date,
        expectedRevision: UInt64
    ) async throws -> MemberMemoryCorrectionResult {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw MemberMemoryUseCaseError.invalidDate
        }
        try Task.checkCancellation()
        return try await store.correctExerciseDisclosure(
            for: memberID,
            at: now,
            expectedRevision: expectedRevision
        )
    }
}

/// Joins the local identity projection with consent state from the separate
/// interaction-memory store. This is the only Application boundary needed by
/// the Debug-Live operator screen; it never uses a display-name lookup or a
/// memory database `members` table.
public struct LoadMemberMemoryManagementProfilesUseCase: Sendable {
    private let store: any MemberInteractionMemoryStore
    private let directory: any MemberMemoryProfileDirectory

    public init(
        store: any MemberInteractionMemoryStore,
        directory: any MemberMemoryProfileDirectory
    ) {
        self.store = store
        self.directory = directory
    }

    public func execute() async throws -> [MemberMemoryManagementProfile] {
        let profiles = try await directory.memberMemoryProfiles()
        var result: [MemberMemoryManagementProfile] = []
        result.reserveCapacity(profiles.count)
        for profile in profiles {
            result.append(
                MemberMemoryManagementProfile(
                    memberID: profile.memberID,
                    spokenLabel: profile.spokenLabel,
                    consent: try await store.consentStatus(for: profile.memberID)
                )
            )
        }
        return result.sorted { lhs, rhs in
            lhs.memberID.rawValue < rhs.memberID.rawValue
        }
    }
}

/// Enables or disables a member's independent interaction-memory consent.
public struct SetMemberMemoryConsentUseCase: Sendable {
    private let store: any MemberInteractionMemoryStore

    public init(store: any MemberInteractionMemoryStore) {
        self.store = store
    }

    public func execute(
        for memberID: MemberID,
        enabled: Bool,
        at consentedAt: Date
    ) async throws {
        guard consentedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MemberMemoryUseCaseError.invalidDate
        }
        let status: MemberMemoryConsentStatus = enabled
            ? .enabled(consentedAt: consentedAt)
            : .disabled
        try await store.setConsent(for: memberID, status: status)
    }
}

/// Removes interaction-memory records while preserving local identity data.
public struct ClearMemberMemoryUseCase: Sendable {
    private let store: any MemberInteractionMemoryStore

    public init(store: any MemberInteractionMemoryStore) {
        self.store = store
    }

    public func execute(for memberID: MemberID) async throws {
        try Task.checkCancellation()
        try await store.clearMemory(for: memberID)
    }
}
