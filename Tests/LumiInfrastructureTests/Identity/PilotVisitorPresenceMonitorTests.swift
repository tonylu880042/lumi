#if DEBUG

import Foundation
import LumiApplication
@testable import LumiInfrastructure
import Testing

@Suite("Pilot visitor presence monitor")
struct PilotVisitorPresenceMonitorTests {
    @Test("arrival ignores empty camera frames until one usable face is present")
    func waitsForUsableFace() async throws {
        let source = PresenceEvidenceSource(results: [
            false,
            false,
            true,
        ])
        let monitor = PilotVisitorPresenceMonitor(
            source: source,
            departureAbsenceDuration: .seconds(10)
        )

        try await monitor.waitForVisitor()

        #expect(await source.startCount == 1)
        #expect(await source.captureCount == 3)
        #expect(await source.stopCount == 1)
    }

    @Test("departure requires ten continuous seconds without a usable face")
    func waitsForContinuousAbsence() async throws {
        let source = PresenceEvidenceSource(results: [
            false,
            true,
            false,
            false,
        ])
        let clock = SequencePresenceClock(values: [
            .seconds(0),
            .seconds(4),
            .seconds(5),
            .seconds(15),
        ])
        let monitor = PilotVisitorPresenceMonitor(
            source: source,
            departureAbsenceDuration: .seconds(10),
            clock: clock
        )

        try await monitor.waitForDeparture()

        #expect(await source.captureCount == 4)
        #expect(await source.stopCount == 1)
    }

    @Test("cancellation is preserved and always stops the camera")
    func cancellationStopsCamera() async throws {
        let source = SuspendedPresenceEvidenceSource()
        let monitor = PilotVisitorPresenceMonitor(
            source: source,
            departureAbsenceDuration: .seconds(10)
        )
        let task = Task { try await monitor.waitForVisitor() }
        await source.waitForCapture()

        task.cancel()
        await source.resumeCapture()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await source.stopCount == 1)
    }

    @Test("monitor failures are payload-free and redact source diagnostics")
    func redactsFailure() async {
        let diagnostics = PresenceDiagnosticRecorder()
        let source = FailingPresenceEvidenceSource()
        let monitor = PilotVisitorPresenceMonitor(
            source: source,
            departureAbsenceDuration: .seconds(10),
            diagnosticSink: diagnostics.record
        )

        await #expect(throws: VisitorPresenceMonitoringError.failed) {
            try await monitor.waitForVisitor()
        }
        #expect(VisitorPresenceMonitoringError.failed.description ==
            "Visitor presence monitoring failed.")
        #expect(VisitorPresenceMonitoringError.failed.customMirror.children.isEmpty)
        #expect(diagnostics.events == [
            .presenceArrivalStarted,
            .presenceArrivalFailedFaceCapture,
        ])
    }

    @Test("distinguishes camera startup failure from face capture failure")
    func recordsCameraStartupFailure() async {
        let diagnostics = PresenceDiagnosticRecorder()
        let monitor = PilotVisitorPresenceMonitor(
            source: StartFailingPresenceEvidenceSource(),
            departureAbsenceDuration: .seconds(10),
            diagnosticSink: diagnostics.record
        )

        await #expect(throws: VisitorPresenceMonitoringError.failed) {
            try await monitor.waitForVisitor()
        }
        #expect(diagnostics.events == [
            .presenceArrivalStarted,
            .presenceArrivalFailedCameraStart,
        ])
    }
}

private final class PresenceDiagnosticRecorder: @unchecked Sendable {
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

private actor PresenceEvidenceSource: PilotVisitorPresenceEvidenceSource {
    private var results: [Bool]
    private(set) var startCount = 0
    private(set) var captureCount = 0
    private(set) var stopCount = 0

    init(results: [Bool]) {
        self.results = results
    }

    func startCamera() async throws { startCount += 1 }
    func stopCamera() async { stopCount += 1 }

    func captureUsableFace() async throws -> Bool {
        captureCount += 1
        guard !results.isEmpty else { throw PresenceTestError.injected }
        return results.removeFirst()
    }
}

private actor SequencePresenceClock: PilotVisitorPresenceClock {
    private var values: [Duration]

    init(values: [Duration]) {
        self.values = values
    }

    func now() -> Duration {
        guard !values.isEmpty else { return .seconds(15) }
        return values.removeFirst()
    }
}

private actor SuspendedPresenceEvidenceSource: PilotVisitorPresenceEvidenceSource {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var stopCount = 0

    func startCamera() async throws {}
    func stopCamera() async { stopCount += 1 }

    func captureUsableFace() async throws -> Bool {
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
        return false
    }

    func waitForCapture() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resumeCapture() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FailingPresenceEvidenceSource: PilotVisitorPresenceEvidenceSource {
    func startCamera() async throws {}
    func stopCamera() async {}
    func captureUsableFace() async throws -> Bool {
        throw PresenceTestError.injected
    }
}

private actor StartFailingPresenceEvidenceSource:
    PilotVisitorPresenceEvidenceSource
{
    func startCamera() async throws { throw PresenceTestError.injected }
    func stopCamera() async {}
    func captureUsableFace() async throws -> Bool { false }
}

private enum PresenceTestError: Error {
    case injected
}

#endif
