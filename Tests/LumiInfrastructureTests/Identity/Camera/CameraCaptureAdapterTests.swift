import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("Camera capture adapter")
struct CameraCaptureAdapterTests {
    @Test("records privacy-safe startup and shutdown outcomes")
    func recordsLifecycleDiagnostics() async throws {
        let successDiagnostics = CameraAdapterDiagnosticRecorder()
        let success = CameraCaptureAdapter(
            permission: RecordingPermissionClient(status: .authorized),
            backend: RecordingCameraBackend(behavior: .immediate),
            diagnosticSink: successDiagnostics.record
        )

        let stream = try await success.start()
        await success.stop()
        #expect(successDiagnostics.events == [
            .cameraStartRequested,
            .cameraStartSucceeded,
            .cameraStopRequested,
            .cameraStopSucceeded,
        ])
        _ = stream

        let deniedDiagnostics = CameraAdapterDiagnosticRecorder()
        let denied = CameraCaptureAdapter(
            permission: RecordingPermissionClient(status: .denied),
            backend: RecordingCameraBackend(behavior: .immediate),
            diagnosticSink: deniedDiagnostics.record
        )

        await #expect(throws: CameraCaptureAdapterError.permissionDenied) {
            try await denied.start()
        }
        #expect(deniedDiagnostics.events == [
            .cameraStartRequested,
            .cameraStartFailedPermissionDenied,
        ])
    }

    @Test("pre-cancelled start does not request permission or start backend")
    func preCancelledStart() async {
        let permission = RecordingPermissionClient(status: .authorized)
        let backend = RecordingCameraBackend(behavior: .immediate)
        let adapter = CameraCaptureAdapter(permission: permission, backend: backend)

        let request = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            try await adapter.start()
        }

        await #expect(throws: CancellationError.self) {
            try await request.value
        }
        #expect(await permission.currentStatusCallCount == 0)
        #expect(await backend.startCallCount == 0)
    }

    @Test("maps denied and restricted permission without starting backend")
    func mapsPermissionFailures() async {
        let deniedPermission = RecordingPermissionClient(status: .denied)
        let deniedBackend = RecordingCameraBackend(behavior: .immediate)
        let deniedAdapter = CameraCaptureAdapter(
            permission: deniedPermission,
            backend: deniedBackend
        )

        await #expect(throws: CameraCaptureAdapterError.permissionDenied) {
            try await deniedAdapter.start()
        }
        #expect(await deniedBackend.startCallCount == 0)

        let restrictedPermission = RecordingPermissionClient(status: .restricted)
        let restrictedBackend = RecordingCameraBackend(behavior: .immediate)
        let restrictedAdapter = CameraCaptureAdapter(
            permission: restrictedPermission,
            backend: restrictedBackend
        )

        await #expect(throws: CameraCaptureAdapterError.permissionRestricted) {
            try await restrictedAdapter.start()
        }
        #expect(await restrictedBackend.startCallCount == 0)
    }

    @Test("requests not-determined permission and starts after authorization")
    func requestsNotDeterminedPermission() async throws {
        let permission = RecordingPermissionClient(
            status: .notDetermined,
            requestedStatus: .authorized
        )
        let backend = RecordingCameraBackend(behavior: .immediate)
        let adapter = CameraCaptureAdapter(permission: permission, backend: backend)

        let stream = try await adapter.start()

        #expect(await permission.requestPermissionCallCount == 1)
        #expect(await backend.startCallCount == 1)
        await adapter.stop()
        _ = stream
    }

    @Test("maps backend categories without exposing backend payloads")
    func mapsBackendFailures() async {
        let unavailable = CameraCaptureAdapter(
            permission: RecordingPermissionClient(status: .authorized),
            backend: RecordingCameraBackend(behavior: .unavailable)
        )
        await #expect(throws: CameraCaptureAdapterError.cameraUnavailable) {
            try await unavailable.start()
        }

        let failed = CameraCaptureAdapter(
            permission: RecordingPermissionClient(status: .authorized),
            backend: RecordingCameraBackend(behavior: .failed)
        )
        await #expect(throws: CameraCaptureAdapterError.captureFailed) {
            try await failed.start()
        }
    }

    @Test("rejects duplicate starts while the first startup is suspended")
    func rejectsDuplicateDuringStarting() async throws {
        let backend = RecordingCameraBackend(behavior: .suspended)
        let adapter = CameraCaptureAdapter(
            permission: RecordingPermissionClient(status: .authorized),
            backend: backend
        )
        let first = Task {
            try await adapter.start()
        }

        await backend.waitForStartRequest()
        await #expect(throws: CameraCaptureAdapterError.alreadyRunning) {
            try await adapter.start()
        }

        await backend.resolveSuspendedStart()
        let stream = try await first.value
        await adapter.stop()
        _ = stream
    }

    @Test("rejects duplicate starts while running")
    func rejectsDuplicateWhileRunning() async throws {
        let backend = RecordingCameraBackend(behavior: .immediate)
        let adapter = CameraCaptureAdapter(
            permission: RecordingPermissionClient(status: .authorized),
            backend: backend
        )

        let stream = try await adapter.start()
        await #expect(throws: CameraCaptureAdapterError.alreadyRunning) {
            try await adapter.start()
        }
        await adapter.stop()
        _ = stream
    }

    @Test("keeps only the newest buffered frame")
    func buffersNewestFrameOnly() async throws {
        let backend = RecordingCameraBackend(behavior: .immediate)
        let adapter = CameraCaptureAdapter(
            permission: RecordingPermissionClient(status: .authorized),
            backend: backend
        )
        let stream = try await adapter.start()
        let runID = await backend.latestRunID()
        let first = try frame(seed: 1)
        let second = try frame(seed: 2)
        let third = try frame(seed: 3)

        await backend.emit(first, forRunID: runID)
        await backend.emit(second, forRunID: runID)
        await backend.emit(third, forRunID: runID)

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == third)
        await adapter.stop()
    }

    @Test("explicit stop is idempotent and stops the owned run once")
    func explicitStopIsIdempotent() async throws {
        let backend = RecordingCameraBackend(behavior: .immediate)
        let adapter = CameraCaptureAdapter(
            permission: RecordingPermissionClient(status: .authorized),
            backend: backend
        )
        let stream = try await adapter.start()
        let run = try #require(await backend.latestRun())

        await adapter.stop()
        await adapter.stop()
        await run.waitForStop()

        #expect(await run.stopCallCount == 1)
        _ = stream
    }

    @Test("stream iterator cancellation stops the owned run once")
    func iteratorCancellationStopsRun() async throws {
        let backend = RecordingCameraBackend(behavior: .immediate)
        let adapter = CameraCaptureAdapter(
            permission: RecordingPermissionClient(status: .authorized),
            backend: backend
        )
        let stream = try await adapter.start()
        let run = try #require(await backend.latestRun())
        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }

        consumer.cancel()
        await consumer.value
        await run.waitForStop()

        #expect(await run.stopCallCount == 1)
    }

    @Test("stopping while backend startup is suspended stops returned run once")
    func stopWhileStartingStopsReturnedRun() async throws {
        let backend = RecordingCameraBackend(behavior: .suspended)
        let adapter = CameraCaptureAdapter(
            permission: RecordingPermissionClient(status: .authorized),
            backend: backend
        )
        let start = Task {
            try await adapter.start()
        }

        await backend.waitForStartRequest()
        await adapter.stop()
        await backend.resolveSuspendedStart()

        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        let run = try #require(await backend.latestRun())
        await run.waitForStop()
        #expect(await run.stopCallCount == 1)
    }

    @Test("cancellation while backend startup is suspended stops returned run once")
    func cancelWhileStartingStopsReturnedRun() async throws {
        let backend = RecordingCameraBackend(behavior: .suspended)
        let adapter = CameraCaptureAdapter(
            permission: RecordingPermissionClient(status: .authorized),
            backend: backend
        )
        let start = Task {
            try await adapter.start()
        }

        await backend.waitForStartRequest()
        start.cancel()
        await backend.resolveSuspendedStart()

        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        let run = try #require(await backend.latestRun())
        await run.waitForStop()
        #expect(await run.stopCallCount == 1)
    }

    @Test("cancel while permission is suspended starts no backend run")
    func cancelWhilePermissionSuspendedStartsNoRun() async throws {
        let permission = BlockingPermissionClient()
        let backend = RecordingCameraBackend(behavior: .immediate)
        let adapter = CameraCaptureAdapter(permission: permission, backend: backend)
        let start = Task {
            try await adapter.start()
        }

        await permission.waitForStatusRequest()
        start.cancel()
        await permission.releaseStatus(.authorized)

        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        #expect(await backend.startCallCount == 0)
    }

    @Test("stale callbacks cannot feed a later generation")
    func staleCallbackSuppressionAndFreshGeneration() async throws {
        let backend = RecordingCameraBackend(behavior: .immediate)
        let adapter = CameraCaptureAdapter(
            permission: RecordingPermissionClient(status: .authorized),
            backend: backend
        )
        let firstStream = try await adapter.start()
        let firstRunID = await backend.latestRunID()
        await adapter.stop()

        let secondStream = try await adapter.start()
        let secondRunID = await backend.latestRunID()
        let stale = try frame(seed: 7)
        let fresh = try frame(seed: 8)
        await backend.emit(stale, forRunID: firstRunID)
        await backend.emit(fresh, forRunID: secondRunID)

        var iterator = secondStream.makeAsyncIterator()
        #expect(await iterator.next() == fresh)
        await adapter.stop()
        _ = firstStream
    }

    @Test("a fresh generation can start after previous cleanup")
    func startsFreshGenerationAfterStop() async throws {
        let backend = RecordingCameraBackend(behavior: .immediate)
        let adapter = CameraCaptureAdapter(
            permission: RecordingPermissionClient(status: .authorized),
            backend: backend
        )

        let first = try await adapter.start()
        await adapter.stop()
        let second = try await adapter.start()

        #expect(await backend.startCallCount == 2)
        await adapter.stop()
        _ = first
        _ = second
    }

    private func frame(seed: UInt8) throws -> CameraFrame {
        try CameraFrame(
            bytes: Data([seed, seed &+ 1, seed &+ 2, seed &+ 3]),
            width: 1,
            height: 1,
            bytesPerRow: 4,
            orientation: .upright
        )
    }
}

private final class CameraAdapterDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [IdentityDiagnosticEvent] = []

    var events: [IdentityDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ event: IdentityDiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }
}

private actor RecordingPermissionClient: CameraPermissionClient {
    let status: CameraPermissionStatus
    let requestedStatus: CameraPermissionStatus
    private(set) var currentStatusCallCount = 0
    private(set) var requestPermissionCallCount = 0

    init(
        status: CameraPermissionStatus,
        requestedStatus: CameraPermissionStatus? = nil
    ) {
        self.status = status
        self.requestedStatus = requestedStatus ?? status
    }

    func currentStatus() async -> CameraPermissionStatus {
        currentStatusCallCount += 1
        return status
    }

    func requestPermission() async -> CameraPermissionStatus {
        requestPermissionCallCount += 1
        return requestedStatus
    }
}

private actor BlockingPermissionClient: CameraPermissionClient {
    private var continuation: CheckedContinuation<CameraPermissionStatus, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func currentStatus() async -> CameraPermissionStatus {
        for waiter in requestWaiters {
            waiter.resume()
        }
        requestWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func requestPermission() async -> CameraPermissionStatus {
        .notDetermined
    }

    func waitForStatusRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter in
            requestWaiters.append(waiter)
        }
    }

    func releaseStatus(_ status: CameraPermissionStatus) {
        continuation?.resume(returning: status)
        continuation = nil
    }
}

private enum TestBackendError: Error, Equatable, Sendable {
    case injected
}

private actor RecordingCameraRun: CameraCaptureRun {
    private(set) var stopCallCount = 0
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    func stop() async {
        stopCallCount += 1
        for waiter in stopWaiters {
            waiter.resume()
        }
        stopWaiters.removeAll()
    }

    func waitForStop() async {
        if stopCallCount > 0 { return }
        await withCheckedContinuation { waiter in
            stopWaiters.append(waiter)
        }
    }
}

private actor RecordingCameraBackend: CameraCaptureBackend {
    enum Behavior: Sendable {
        case immediate
        case suspended
        case unavailable
        case failed
    }

    private struct PendingStart {
        let id: UInt64
        let continuation: CheckedContinuation<any CameraCaptureRun, any Error>
    }

    let behavior: Behavior
    private(set) var startCallCount = 0
    private var nextRunID: UInt64 = 0
    private var latestID: UInt64?
    private var latestRunValue: RecordingCameraRun?
    private var handlers: [UInt64: @Sendable (CameraFrame) -> Void] = [:]
    private var runs: [UInt64: RecordingCameraRun] = [:]
    private var pendingStart: PendingStart?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func start(
        frameHandler: @escaping @Sendable (CameraFrame) -> Void
    ) async throws -> any CameraCaptureRun {
        startCallCount += 1
        let id = nextRunID
        nextRunID &+= 1
        latestID = id
        handlers[id] = frameHandler

        switch behavior {
        case .immediate:
            let run = RecordingCameraRun()
            latestRunValue = run
            runs[id] = run
            return run
        case .suspended:
            let runContinuation = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<any CameraCaptureRun, any Error>) in
                pendingStart = PendingStart(id: id, continuation: continuation)
                for waiter in startWaiters {
                    waiter.resume()
                }
                startWaiters.removeAll()
            }
            return runContinuation
        case .unavailable:
            throw CameraCaptureBackendError.unavailable
        case .failed:
            throw TestBackendError.injected
        }
    }

    func waitForStartRequest() async {
        if pendingStart != nil || startCallCount > 0 && behavior != .suspended {
            return
        }
        await withCheckedContinuation { waiter in
            startWaiters.append(waiter)
        }
    }

    func resolveSuspendedStart() {
        guard let pendingStart else { return }
        let run = RecordingCameraRun()
        latestRunValue = run
        runs[pendingStart.id] = run
        self.pendingStart = nil
        pendingStart.continuation.resume(returning: run)
    }

    func latestRunID() -> UInt64 {
        latestID!
    }

    func latestRun() -> RecordingCameraRun? {
        latestRunValue
    }

    func emit(_ frame: CameraFrame, forRunID id: UInt64) {
        handlers[id]?(frame)
    }
}
