import Foundation

/// Payload-free failures a platform backend may report to its adapter.
enum CameraCaptureBackendError: Error, Equatable, Sendable {
    case unavailable
    case failed
}

/// Stable, privacy-safe failures exposed by the capture adapter.
enum CameraCaptureAdapterError: Error, Equatable, Sendable {
    case alreadyRunning
    case permissionDenied
    case permissionRestricted
    case cameraUnavailable
    case captureFailed
}

/// A single backend capture generation and its owned stop operation.
///
/// A run is returned only after a backend has atomically started. Keeping stop
/// on the returned run prevents one adapter generation from stopping a later
/// generation that happens to share the same backend instance.
protocol CameraCaptureRun: Sendable {
    func stop() async
}

/// Platform-local capture backend boundary.
///
/// The synchronous frame handler is called on the backend's delivery context.
/// It accepts only an owned, Sendable `CameraFrame`; native sample-buffer and
/// pixel-buffer objects must be copied before invoking it.
protocol CameraCaptureBackend: Sendable {
    func start(
        frameHandler: @escaping @Sendable (CameraFrame) -> Void
    ) async throws -> any CameraCaptureRun
}

/// Coordinates permission, one active capture generation, and its frame stream.
///
/// The adapter deliberately leaves capture resolution, frame rate, target
/// selection, and UI/lifecycle policy to callers. It only guarantees one
/// active generation, newest-one buffering, and exactly-once run cleanup.
actor CameraCaptureAdapter {
    private enum Phase {
        case idle
        case starting(UInt64)
        case running(UInt64)
        case stopping(UInt64)
    }

    private let permission: any CameraPermissionClient
    private let backend: any CameraCaptureBackend
    private let diagnosticSink: IdentityDiagnosticSink

    private var phase: Phase = .idle
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?
    private var streamContinuation: AsyncStream<CameraFrame>.Continuation?
    private var activeRun: (any CameraCaptureRun)?
    private var stopIssued = false
    private var startupCancellationRequested = false
    private var stopCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        permission: any CameraPermissionClient,
        backend: any CameraCaptureBackend,
        diagnosticSink: @escaping IdentityDiagnosticSink =
            IdentityDiagnostics.record
    ) {
        self.permission = permission
        self.backend = backend
        self.diagnosticSink = diagnosticSink
    }

    /// Starts one capture generation and returns its bounded frame stream.
    ///
    /// Cancellation is checked before permission and again before backend
    /// startup. If cancellation or `stop()` wins while startup is suspended,
    /// a run returned later is stopped before this method throws
    /// `CancellationError`.
    func start() async throws -> AsyncStream<CameraFrame> {
        try Task.checkCancellation()
        diagnosticSink(.cameraStartRequested)
        guard case .idle = phase else {
            diagnosticSink(.cameraStartFailedAlreadyRunning)
            throw CameraCaptureAdapterError.alreadyRunning
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        let streamPair = AsyncStream<CameraFrame>.makeStream(
            of: CameraFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )

        phase = .starting(generation)
        activeGeneration = generation
        streamContinuation = streamPair.continuation
        activeRun = nil
        stopIssued = false
        startupCancellationRequested = false

        streamPair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.streamTerminated(generation: generation)
            }
        }

        do {
            try await permission.authorize()
            try Task.checkCancellation()
            guard isStarting(generation), !startupCancellationRequested else {
                throw CancellationError()
            }

            let run = try await backend.start(
                frameHandler: { frame in
                    // The continuation belongs exclusively to this
                    // generation. Once finished by stop/termination, yields
                    // are ignored and cannot reach a later stream.
                    _ = streamPair.continuation.yield(frame)
                }
            )

            guard !Task.isCancelled,
                  isStarting(generation),
                  !startupCancellationRequested
            else {
                await run.stop()
                finishGeneration(generation)
                throw CancellationError()
            }

            activeRun = run
            phase = .running(generation)
            diagnosticSink(.cameraStartSucceeded)
            return streamPair.stream
        } catch {
            let cancelled = error is CancellationError
                || Task.isCancelled
                || startupCancellationRequested
            finishGeneration(generation)
            if cancelled {
                diagnosticSink(.cameraStartCancelled)
                throw CancellationError()
            }
            let mappedError = map(error)
            diagnosticSink(diagnosticEvent(for: mappedError))
            throw mappedError
        }
    }

    /// Stops the active generation. Repeated calls are idempotent and wait for
    /// an already-issued run stop to finish before returning.
    func stop() async {
        guard let generation = activeGeneration else { return }
        diagnosticSink(.cameraStopRequested)

        startupCancellationRequested = true
        switch phase {
        case .idle:
            return
        case .starting(let active), .running(let active):
            guard active == generation else { return }
            phase = .stopping(generation)
        case .stopping(let active):
            guard active == generation else { return }
        }

        streamContinuation?.finish()
        streamContinuation = nil

        guard let run = activeRun else {
            // Startup is still suspended. The start method owns the eventual
            // run and will stop it exactly once when the backend returns.
            return
        }

        if stopIssued {
            await waitForStopCompletion()
            return
        }

        stopIssued = true
        await run.stop()
        finishGeneration(generation)
        diagnosticSink(.cameraStopSucceeded)
    }

    private func streamTerminated(generation: UInt64) async {
        guard activeGeneration == generation else { return }
        await stop()
    }

    private func isStarting(_ generation: UInt64) -> Bool {
        guard activeGeneration == generation else { return false }
        guard case .starting(let active) = phase else { return false }
        return active == generation
    }

    private func waitForStopCompletion() async {
        await withCheckedContinuation { continuation in
            stopCompletionWaiters.append(continuation)
        }
    }

    private func finishGeneration(_ generation: UInt64) {
        guard activeGeneration == generation else { return }

        streamContinuation?.finish()
        streamContinuation = nil
        activeRun = nil
        activeGeneration = nil
        phase = .idle
        stopIssued = false
        startupCancellationRequested = false

        let waiters = stopCompletionWaiters
        stopCompletionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func map(_ error: any Error) -> CameraCaptureAdapterError {
        if let permissionError = error as? CameraPermissionError {
            switch permissionError {
            case .denied:
                return .permissionDenied
            case .restricted:
                return .permissionRestricted
            }
        }

        if let backendError = error as? CameraCaptureBackendError {
            switch backendError {
            case .unavailable:
                return .cameraUnavailable
            case .failed:
                return .captureFailed
            }
        }

        return .captureFailed
    }

    private func diagnosticEvent(
        for error: CameraCaptureAdapterError
    ) -> IdentityDiagnosticEvent {
        switch error {
        case .alreadyRunning:
            .cameraStartFailedAlreadyRunning
        case .permissionDenied:
            .cameraStartFailedPermissionDenied
        case .permissionRestricted:
            .cameraStartFailedPermissionRestricted
        case .cameraUnavailable:
            .cameraStartFailedUnavailable
        case .captureFailed:
            .cameraStartFailedCapture
        }
    }
}
