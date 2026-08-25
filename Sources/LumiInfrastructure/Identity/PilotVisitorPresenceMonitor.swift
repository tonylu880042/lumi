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
    private enum Operation {
        case arrival
        case departure

        var started: IdentityDiagnosticEvent {
            self == .arrival ? .presenceArrivalStarted : .presenceDepartureStarted
        }

        var succeeded: IdentityDiagnosticEvent {
            self == .arrival ? .presenceArrivalSucceeded : .presenceDepartureSucceeded
        }

        var cancelled: IdentityDiagnosticEvent {
            self == .arrival ? .presenceArrivalCancelled : .presenceDepartureCancelled
        }

        var cameraStartFailed: IdentityDiagnosticEvent {
            self == .arrival
                ? .presenceArrivalFailedCameraStart
                : .presenceDepartureFailedCameraStart
        }

        var faceCaptureFailed: IdentityDiagnosticEvent {
            self == .arrival
                ? .presenceArrivalFailedFaceCapture
                : .presenceDepartureFailedFaceCapture
        }
    }

    private let source: any PilotVisitorPresenceEvidenceSource
    private let departureAbsenceDuration: Duration
    private let clock: any PilotVisitorPresenceClock
    private let diagnosticSink: IdentityDiagnosticSink
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        source: any PilotVisitorPresenceEvidenceSource,
        departureAbsenceDuration: Duration
    ) {
        self.source = source
        self.departureAbsenceDuration = departureAbsenceDuration
        self.clock = ContinuousPilotVisitorPresenceClock()
        self.diagnosticSink = IdentityDiagnostics.record
    }

    init(
        source: any PilotVisitorPresenceEvidenceSource,
        departureAbsenceDuration: Duration,
        diagnosticSink: @escaping IdentityDiagnosticSink
    ) {
        self.source = source
        self.departureAbsenceDuration = departureAbsenceDuration
        self.clock = ContinuousPilotVisitorPresenceClock()
        self.diagnosticSink = diagnosticSink
    }

    init(
        source: any PilotVisitorPresenceEvidenceSource,
        departureAbsenceDuration: Duration,
        clock: any PilotVisitorPresenceClock,
        diagnosticSink: @escaping IdentityDiagnosticSink =
            IdentityDiagnostics.record
    ) {
        self.source = source
        self.departureAbsenceDuration = departureAbsenceDuration
        self.clock = clock
        self.diagnosticSink = diagnosticSink
    }

    public func waitForVisitor() async throws {
        try await runCameraOperation(.arrival) { [source] in
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
        try await runCameraOperation(.departure) { [source] in
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
        _ kind: Operation,
        _ operation: @Sendable () async throws -> Void
    ) async throws {
        try await acquireOperationSlot()
        defer { releaseOperationSlot() }
        diagnosticSink(kind.started)

        do {
            try Task.checkCancellation()
            try await source.startCamera()
            try Task.checkCancellation()
        } catch let cancellation as CancellationError {
            await source.stopCamera()
            diagnosticSink(kind.cancelled)
            throw cancellation
        } catch {
            await source.stopCamera()
            if Task.isCancelled {
                diagnosticSink(kind.cancelled)
                throw CancellationError()
            }
            diagnosticSink(kind.cameraStartFailed)
            throw VisitorPresenceMonitoringError.failed
        }

        do {
            try await operation()
            await source.stopCamera()
            try Task.checkCancellation()
            diagnosticSink(kind.succeeded)
        } catch let cancellation as CancellationError {
            await source.stopCamera()
            diagnosticSink(kind.cancelled)
            throw cancellation
        } catch {
            await source.stopCamera()
            if Task.isCancelled {
                diagnosticSink(kind.cancelled)
                throw CancellationError()
            }
            diagnosticSink(kind.faceCaptureFailed)
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
