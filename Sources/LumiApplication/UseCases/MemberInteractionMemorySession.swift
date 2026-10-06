import Foundation
import LumiDomain

struct MemberExerciseDisclosureSessionState: Equatable, Sendable {
    let disclosure: MemberExerciseDisclosure?
    let recordedAt: Date?

    init(
        disclosure: MemberExerciseDisclosure?,
        recordedAt: Date?
    ) {
        self.disclosure = disclosure
        self.recordedAt = recordedAt
    }
}

/// Coordinates revisioned memory writes that belong to one known-member
/// session. The actor is shared by the coordinator's greeting completion and
/// the voice tool runner so a successful meeting write hands its new revision
/// to a later exercise disclosure instead of making that write stale.
public actor MemberInteractionMemorySession {
    public let memberID: MemberID
    public let sessionID: String

    private let meetingUseCase: RecordMemberMeetingUseCase
    private let exerciseUseCase: RecordMemberExerciseDisclosureUseCase
    private let correctionUseCase: CorrectMemberExerciseDisclosureUseCase
    private var revision: UInt64
    private var invalidated = false
    private var currentExerciseDisclosure: MemberExerciseDisclosure?
    private var currentExerciseDisclosureRecordedAt: Date?
    private var writeInFlight = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        memberID: MemberID,
        sessionID: String,
        initialRevision: UInt64,
        initialExerciseDisclosure: MemberExerciseDisclosure? = nil,
        initialExerciseDisclosureRecordedAt: Date? = nil,
        store: any MemberInteractionMemoryStore
    ) {
        self.memberID = memberID
        self.sessionID = sessionID
        self.revision = initialRevision
        if initialExerciseDisclosure == .completedToday,
           let recordedAt = initialExerciseDisclosureRecordedAt,
           recordedAt.timeIntervalSinceReferenceDate.isFinite
        {
            self.currentExerciseDisclosure = .completedToday
            self.currentExerciseDisclosureRecordedAt = recordedAt
        } else if initialExerciseDisclosure == .completedToday {
            // A persistent completion without its source timestamp cannot be
            // proven current and must never cross the provider boundary.
            self.currentExerciseDisclosure = nil
            self.currentExerciseDisclosureRecordedAt = nil
        } else {
            self.currentExerciseDisclosure = initialExerciseDisclosure
            self.currentExerciseDisclosureRecordedAt = nil
        }
        self.meetingUseCase = RecordMemberMeetingUseCase(store: store)
        self.exerciseUseCase = RecordMemberExerciseDisclosureUseCase(store: store)
        self.correctionUseCase = CorrectMemberExerciseDisclosureUseCase(store: store)
    }

    public func recordMeeting(
        at recordedAt: Date
    ) async throws -> MemberMemoryAppendResult {
        await acquireWrite()
        defer { releaseWrite() }
        guard !invalidated else {
            return rejectedResult()
        }
        let result = try await meetingUseCase.execute(
            for: memberID,
            sessionID: sessionID,
            at: recordedAt,
            expectedRevision: revision
        )
        guard !invalidated else {
            return rejectedResult()
        }
        apply(result)
        return result
    }

    /// Corrects a persistent current-day completion and clears any
    /// session-only state held by this Application-owned session.
    public func correctExerciseDisclosure(
        at recordedAt: Date
    ) async throws -> MemberMemoryCorrectionResult {
        await acquireWrite()
        defer { releaseWrite() }
        guard !invalidated else {
            return MemberMemoryCorrectionResult(
                outcome: .rejected,
                revision: revision
            )
        }
        let result = try await correctionUseCase.execute(
            for: memberID,
            at: recordedAt,
            expectedRevision: revision
        )
        guard !invalidated else {
            return MemberMemoryCorrectionResult(
                outcome: .rejected,
                revision: revision
            )
        }
        revision = result.revision
        if result.outcome == .corrected || result.outcome == .notFound {
            currentExerciseDisclosure = nil
            currentExerciseDisclosureRecordedAt = nil
        }
        return result
    }

    /// The bounded state currently known in this session. `preparing` and
    /// `justCompleted` deliberately live only here; `completedToday` may be
    /// rehydrated by the initial persistent snapshot.
    public func currentExerciseState() -> MemberExerciseDisclosure? {
        currentExerciseState(at: Date())
    }

    public func currentExerciseState(at now: Date) -> MemberExerciseDisclosure? {
        currentExerciseMemoryState(at: now).disclosure
    }

    func currentExerciseMemoryState(
        at now: Date
    ) -> MemberExerciseDisclosureSessionState {
        expireCompletedTodayIfNeeded(at: now)
        return MemberExerciseDisclosureSessionState(
            disclosure: currentExerciseDisclosure,
            recordedAt: currentExerciseDisclosureRecordedAt
        )
    }

    public func recordExerciseDisclosure(
        _ disclosure: MemberExerciseDisclosure,
        at recordedAt: Date
    ) async throws -> MemberMemoryAppendResult {
        await acquireWrite()
        defer { releaseWrite() }
        guard !invalidated else {
            return rejectedResult()
        }
        let result = try await exerciseUseCase.execute(
            for: memberID,
            disclosure: disclosure,
            interactionID: "\(sessionID):exercise:\(Self.disclosureIdentifier(disclosure))",
            at: recordedAt,
            expectedRevision: revision
        )
        guard !invalidated else {
            return rejectedResult()
        }
        apply(result)
        if result.outcome == .appended || result.outcome == .ignored {
            currentExerciseDisclosure = disclosure
            currentExerciseDisclosureRecordedAt = recordedAt
        }
        return result
    }

    /// Invalidates a loaded context after a management clear/disable or an
    /// otherwise failed revision guard. Existing provider instructions must
    /// not be used for a later memory claim.
    public func invalidate() {
        invalidated = true
    }

    public func isValid() -> Bool { !invalidated }

    private func apply(_ result: MemberMemoryAppendResult) {
        revision = result.revision
        if result.outcome == .rejected {
            invalidated = true
        }
    }

    private func rejectedResult() -> MemberMemoryAppendResult {
        MemberMemoryAppendResult(outcome: .rejected, revision: revision)
    }

    private func expireCompletedTodayIfNeeded(at now: Date) {
        guard let disclosure = currentExerciseDisclosure else { return }
        guard MemberInteractionMemoryPolicy.isExerciseDisclosureActive(
            disclosure,
            recordedAt: currentExerciseDisclosureRecordedAt,
            at: now
        ) else {
            // Any missing or contradictory timestamp, including a clock
            // rollback, fails closed.
            currentExerciseDisclosure = nil
            currentExerciseDisclosureRecordedAt = nil
            return
        }
    }

    private static func disclosureIdentifier(
        _ disclosure: MemberExerciseDisclosure
    ) -> String {
        switch disclosure {
        case .preparing:
            "preparing"
        case .justCompleted:
            "just_completed"
        case .completedToday:
            "completed_today"
        }
    }

    private func acquireWrite() async {
        guard writeInFlight else {
            writeInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            writeWaiters.append(continuation)
        }
    }

    private func releaseWrite() {
        guard let continuation = writeWaiters.first else {
            writeInFlight = false
            return
        }
        writeWaiters.removeFirst()
        continuation.resume()
    }
}
