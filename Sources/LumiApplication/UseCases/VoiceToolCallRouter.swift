import Foundation

/// Routes normalized voice calls to Application use cases for one voice
/// session.
///
/// The instance is session-scoped. It remembers completed calls by their
/// opaque call ID so a repeated completed call returns the exact same result
/// without querying the repository again. Stream consumption is expected to
/// invoke this method serially; concurrent in-flight call coalescing is
/// intentionally deferred to the stream runner.
public actor VoiceToolCallRouter {
    private let weeklySummaryUseCase: GetMemberWeeklySummaryUseCase
    private var completedCalls: [String: CompletedCall] = [:]

    public init(weeklySummaryUseCase: GetMemberWeeklySummaryUseCase) {
        self.weeklySummaryUseCase = weeklySummaryUseCase
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
        case let .getMemberWeeklySummary(memberID):
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
