import LumiApplication
import LumiDomain

/// Failures that are specific to the deterministic mock adapter.
public enum MockHardwareControlError: Error, Equatable, Sendable {
    case rotationInProgress
    case returnHomeInProgress
}

/// Deterministic hardware adapter for Application tests and Simulator flows.
///
/// A movement command is accepted once and remains pending until its explicit
/// arrival or failure control is called. No wall-clock delay is used.
public actor MockHardwareControlPort: HardwareControlPort {
    public private(set) var rotationTargets: [RotationAngle] = []
    public private(set) var returnHomeCallCount = 0
    public private(set) var stopCallCount = 0

    private struct PendingRotation {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct PendingReturnHome {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private enum PendingMovement {
        case rotation(PendingRotation)
        case returnHome(PendingReturnHome)
    }

    private var nextRotationID: UInt64 = 0
    private var nextReturnHomeID: UInt64 = 0
    private var pendingMovement: PendingMovement?

    public init() {}

    /// Whether a return-home request is waiting for explicit arrival.
    public var hasPendingReturnHome: Bool {
        guard let pendingMovement else { return false }
        if case .returnHome = pendingMovement { return true }
        return false
    }

    public func rotate(to angle: RotationAngle) async throws {
        let requestID = nextRotationID
        nextRotationID &+= 1

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                if let currentMovement = pendingMovement {
                    let error: MockHardwareControlError
                    switch currentMovement {
                    case .rotation:
                        error = .rotationInProgress
                    case .returnHome:
                        error = .returnHomeInProgress
                    }
                    continuation.resume(throwing: error)
                    return
                }

                rotationTargets.append(angle)
                pendingMovement = .rotation(
                    PendingRotation(id: requestID, continuation: continuation)
                )
            }
        }, onCancel: {
            Task { await self.cancelPendingRotation(id: requestID) }
        })
    }

    public func completeRotation() {
        guard case let .rotation(pendingRotation)? = pendingMovement else { return }
        self.pendingMovement = nil
        pendingRotation.continuation.resume()
    }

    public func returnHome() async throws {
        let requestID = nextReturnHomeID
        nextReturnHomeID &+= 1
        returnHomeCallCount += 1

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                if let currentMovement = pendingMovement {
                    let error: MockHardwareControlError
                    switch currentMovement {
                    case .rotation:
                        error = .rotationInProgress
                    case .returnHome:
                        error = .returnHomeInProgress
                    }
                    continuation.resume(throwing: error)
                    return
                }

                pendingMovement = .returnHome(
                    PendingReturnHome(id: requestID, continuation: continuation)
                )
            }
        }, onCancel: {
            Task { await self.cancelPendingReturnHome(id: requestID) }
        })
    }

    /// Completes the pending return-home request after confirmed Home arrival.
    /// Calling this with no pending return-home request is intentionally a no-op.
    public func completeReturnHome() {
        guard case let .returnHome(pendingReturnHome)? = pendingMovement else { return }
        self.pendingMovement = nil
        pendingReturnHome.continuation.resume()
    }

    /// Fails the pending return-home request with an injected adapter error.
    /// Calling this with no pending return-home request is intentionally a no-op.
    public func failPendingReturnHome(with error: any Error) {
        guard case let .returnHome(pendingReturnHome)? = pendingMovement else { return }
        self.pendingMovement = nil
        pendingReturnHome.continuation.resume(throwing: error)
    }

    public func stop() async {
        stopCallCount += 1
        cancelCurrentMovement()
    }

    private func cancelPendingRotation(id: UInt64) {
        guard case let .rotation(pendingRotation)? = pendingMovement,
              pendingRotation.id == id else { return }
        self.pendingMovement = nil
        pendingRotation.continuation.resume(throwing: CancellationError())
    }

    private func cancelPendingReturnHome(id: UInt64) {
        guard case let .returnHome(pendingReturnHome)? = pendingMovement,
              pendingReturnHome.id == id else { return }
        self.pendingMovement = nil
        pendingReturnHome.continuation.resume(throwing: CancellationError())
    }

    private func cancelCurrentMovement() {
        guard let pendingMovement else { return }
        self.pendingMovement = nil

        switch pendingMovement {
        case let .rotation(pendingRotation):
            pendingRotation.continuation.resume(throwing: CancellationError())
        case let .returnHome(pendingReturnHome):
            pendingReturnHome.continuation.resume(throwing: CancellationError())
        }
    }
}
