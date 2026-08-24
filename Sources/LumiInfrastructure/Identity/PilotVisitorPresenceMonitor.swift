#if DEBUG

import LumiApplication

/// Narrow face-presence seam. Unlike identity evidence, this operation never
/// loads or ranks the enrollment gallery.
public protocol PilotVisitorPresenceEvidenceSource: Sendable {
    func startCamera() async throws
    func stopCamera() async
    func captureUsableFace() async throws -> Bool
}

/// Monotonic time seam for deterministic continuous-absence tests.
protocol PilotVisitorPresenceClock: Sendable {
    func now() async -> Duration
}

private struct ContinuousPilotVisitorPresenceClock: PilotVisitorPresenceClock {
    private let origin = ContinuousClock.now

    func now() -> Duration {
        origin.duration(to: .now)
    }
}

/// DEBUG-Live presence monitor reusing the already validated camera and face
/// pipeline. A true observation means one usable face was found without
/// loading or matching the enrollment gallery.
public actor PilotVisitorPresenceMonitor: VisitorPresenceMonitoringPort {
    private let source: any PilotVisitorPresenceEvidenceSource
    private let departureAbsenceDuration: Duration
    private let clock: any PilotVisitorPresenceClock
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        source: any PilotVisitorPresenceEvidenceSource,
        departureAbsenceDuration: Duration
    ) {
        self.source = source
        self.departureAbsenceDuration = departureAbsenceDuration
        self.clock = ContinuousPilotVisitorPresenceClock()
    }

    init(
        source: any PilotVisitorPresenceEvidenceSource,
        departureAbsenceDuration: Duration,
        clock: any PilotVisitorPresenceClock
    ) {
        self.source = source
        self.departureAbsenceDuration = departureAbsenceDuration
        self.clock = clock
    }

    public func waitForVisitor() async throws {
        try await runCameraOperation { [source] in
            while true {
                try Task.checkCancellation()
                if try await source.captureUsableFace() {
                    return
                }
            }
        }
    }

    public func waitForDeparture() async throws {
        let clock = self.clock
        let absenceDuration = departureAbsenceDuration
        try await runCameraOperation { [source] in
            var absenceStartedAt: Duration?
            while true {
                try Task.checkCancellation()
                let hasUsableFace = try await source.captureUsableFace()
                let now = await clock.now()
                if hasUsableFace {
                    absenceStartedAt = nil
                } else {
                    if let absenceStartedAt {
                        if now >= absenceStartedAt + absenceDuration {
                            return
                        }
                    } else {
                        absenceStartedAt = now
                    }
                }
            }
        }
    }

    public func stop() async {
        await source.stopCamera()
    }

    private func runCameraOperation(
        _ operation: @Sendable () async throws -> Void
    ) async throws {
        try await acquireOperationSlot()
        defer { releaseOperationSlot() }

        do {
            try Task.checkCancellation()
            try await source.startCamera()
            try Task.checkCancellation()
            try await operation()
            await source.stopCamera()
            try Task.checkCancellation()
        } catch let cancellation as CancellationError {
            await source.stopCamera()
            throw cancellation
        } catch {
            await source.stopCamera()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw VisitorPresenceMonitoringError.failed
        }
    }

    private func acquireOperationSlot() async throws {
        while operationInProgress {
            try Task.checkCancellation()
            await withCheckedContinuation { continuation in
                operationWaiters.append(continuation)
            }
        }
        try Task.checkCancellation()
        operationInProgress = true
    }

    private func releaseOperationSlot() {
        operationInProgress = false
        let waiters = operationWaiters
        operationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

extension CoreMLIdentityCalibrationService: PilotVisitorPresenceEvidenceSource {}

#endif
