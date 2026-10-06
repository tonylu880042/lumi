import Foundation
import LumiDomain

/// Routes normalized voice calls to Application use cases for one voice
/// session.
///
/// The instance is session-scoped. It remembers completed calls by their
/// opaque call ID so a repeated completed call returns the exact same result
/// without querying the repository again. Stream consumption is expected to
/// invoke this method serially; concurrent in-flight call coalescing is
/// intentionally deferred to the stream runner.
public actor VoiceToolCallRouter {
    private let memberID: MemberID
    private let weeklySummaryUseCase: GetMemberWeeklySummaryUseCase?
    private let memorySession: MemberInteractionMemorySession?
    private let now: @Sendable () -> Date
    private let memoryContextDidChange:
        (@Sendable (MemberExerciseDisclosure?, Date) async -> Void)?
    private var completedCalls: [String: CompletedCall] = [:]

    public init(
        memberID: MemberID,
        weeklySummaryUseCase: GetMemberWeeklySummaryUseCase? = nil,
        memorySession: MemberInteractionMemorySession? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        memoryContextDidChange:
            (@Sendable (MemberExerciseDisclosure?, Date) async -> Void)? = nil
    ) {
        self.memberID = memberID
        self.weeklySummaryUseCase = weeklySummaryUseCase
        self.memorySession = memorySession
        self.now = now
        self.memoryContextDidChange = memoryContextDidChange
    }

    /// Returns the deterministic result for one normalized voice call.
    ///
    /// Completed calls are idempotent within this router's session. A reused
    /// call ID with a different call kind receives `duplicate_call` and does
    /// not replace the original cached result. Cancellation always wins and
    /// never adds a result to the session cache.
    public func result(for call: VoiceToolCall) async throws -> VoiceToolResult {
        try Task.checkCancellation()

        if let completedCall = completedCalls[call.callID] {
            guard completedCall.kind == call.kind else {
                return VoiceToolResult(
                    callID: call.callID,
                    payload: .failure(.duplicateCall)
                )
            }
            return completedCall.result
        }

        let payload: VoiceToolResultPayload
        switch call.kind {
        case .getMemberWeeklySummary:
            guard let weeklySummaryUseCase else {
                payload = .failure(.memberDataUnavailable)
                break
            }
            do {
                let summary = try await weeklySummaryUseCase.execute(for: memberID)
                try Task.checkCancellation()
                payload = .success(summary)
            } catch {
                if error is CancellationError {
                    throw error
                }
                if Task.isCancelled {
                    throw CancellationError()
                }

                if let error = error as? GetMemberWeeklySummaryError {
                    switch error {
                    case .repositoryUnavailable:
                        payload = .failure(.memberDataUnavailable)
                    case .invalidData:
                        payload = .failure(.invalidData)
                    }
                } else {
                    payload = .failure(.memberDataUnavailable)
                }
            }

        case let .recordExerciseDisclosure(disclosure):
            guard let memorySession else {
                payload = .failure(.memberMemoryUnavailable)
                break
            }
            do {
                let recordedAt = now()
                let write = try await memorySession.recordExerciseDisclosure(
                    disclosure,
                    at: recordedAt
                )
                try Task.checkCancellation()
                switch write.outcome {
                case .appended, .duplicate, .ignored:
                    // `.ignored` is the intentional Application result for
                    // session-only states. It is accepted in the current
                    // session and must still reach the provider context;
                    // only the SQLite persistence write is skipped.
                    await memoryContextDidChange?(disclosure, recordedAt)
                    payload = .exerciseDisclosureRecorded(disclosure)
                case .rejected:
                    payload = .failure(.memberMemoryUnavailable)
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                payload = .failure(.memberMemoryUnavailable)
            }

        case .correctMemberExerciseDisclosure:
            guard let memorySession else {
                payload = .failure(.memberMemoryUnavailable)
                break
            }
            do {
                let correctedAt = now()
                let correction = try await memorySession.correctExerciseDisclosure(
                    at: correctedAt
                )
                try Task.checkCancellation()
                switch correction.outcome {
                case .corrected:
                    await memoryContextDidChange?(nil, correctedAt)
                    payload = .exerciseDisclosureCorrected
                case .notFound:
                    await memoryContextDidChange?(nil, correctedAt)
                    payload = .exerciseDisclosureCorrectionNotFound
                case .rejected:
                    payload = .failure(.memberMemoryUnavailable)
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                payload = .failure(.memberMemoryUnavailable)
            }

        case .beginVisitorEnrollment, .completeVisitorEnrollment, .endConversation:
            payload = .failure(.unsupportedTool)

        case .unsupported:
            payload = .failure(.unsupportedTool)

        case .invalidArguments:
            payload = .failure(.invalidArguments)
        }

        try Task.checkCancellation()

        let result = VoiceToolResult(callID: call.callID, payload: payload)
        completedCalls[call.callID] = CompletedCall(kind: call.kind, result: result)
        return result
    }
}

private struct CompletedCall: Sendable {
    let kind: VoiceToolCallKind
    let result: VoiceToolResult
}
