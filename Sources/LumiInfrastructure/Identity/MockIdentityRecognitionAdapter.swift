import LumiApplication
import LumiDomain

/// Failures that are specific to the deterministic identity mock.
public enum MockIdentityRecognitionError: Error, Equatable, Sendable {
    case operationInProgress
}

/// Deterministic identity adapter for Application tests and Simulator flows.
///
/// A recognition request remains suspended until the test explicitly resolves
/// it with `complete(with:)` or `fail(with:)`. There is never more than one
/// pending request, and no wall-clock delay is used.
public actor MockIdentityRecognitionAdapter: IdentityRecognitionPort {
    public private(set) var callCount = 0

    /// Whether a request is currently waiting for an explicit resolution.
    public var hasPendingRequest: Bool {
        pendingRequest != nil
    }

    private struct PendingRequest {
        let id: UInt64
        let continuation: CheckedContinuation<RecognitionResult, any Error>
    }

    private var nextRequestID: UInt64 = 0
    private var pendingRequest: PendingRequest?

    public init() {}

    public func recognizeCurrentVisitor() async throws -> RecognitionResult {
        let requestID = nextRequestID
        nextRequestID &+= 1
        callCount += 1

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<RecognitionResult, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                guard pendingRequest == nil else {
                    continuation.resume(
                        throwing: MockIdentityRecognitionError.operationInProgress
                    )
                    return
                }

                pendingRequest = PendingRequest(
                    id: requestID,
                    continuation: continuation
                )
            }
        }, onCancel: {
            Task { await self.cancelPendingRequest(id: requestID) }
        })
    }

    /// Resolves the active recognition request with the supplied semantic result.
    /// Calling this when no matching request is pending is intentionally a no-op.
    public func complete(with result: RecognitionResult) {
        guard let pendingRequest else { return }
        self.pendingRequest = nil
        pendingRequest.continuation.resume(returning: result)
    }

    /// Fails the active recognition request with an injected adapter error.
    /// Calling this when no request is pending is intentionally a no-op.
    public func fail(with error: any Error) {
        guard let pendingRequest else { return }
        self.pendingRequest = nil
        pendingRequest.continuation.resume(throwing: error)
    }

    private func cancelPendingRequest(id requestID: UInt64) {
        guard let pendingRequest, pendingRequest.id == requestID else { return }
        self.pendingRequest = nil
        pendingRequest.continuation.resume(throwing: CancellationError())
    }
}
