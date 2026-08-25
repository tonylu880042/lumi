import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("AVFoundation camera capture backend")
struct AVFoundationCameraCaptureBackendTests {
    @Test("records exact redacted driver startup failures")
    func recordsDriverFailureDiagnostics() async {
        let cases: [(RecordingCaptureDriver.Failure, IdentityDiagnosticEvent)] = [
            (.noFrontCamera, .cameraBackendFailedNoFrontCamera),
            (.cannotAddInput, .cameraBackendFailedCannotAddInput),
            (.cannotAddOutput, .cameraBackendFailedCannotAddOutput),
            (.unsupportedPixelFormat, .cameraBackendFailedUnsupportedPixelFormat),
            (.unsupportedRotation, .cameraBackendFailedUnsupportedRotation),
            (.cannotGuaranteeNonMirrored, .cameraBackendFailedMirroring),
            (.unexpected, .cameraBackendFailedUnexpected),
        ]

        for (failure, expected) in cases {
            let diagnostics = CameraBackendDiagnosticRecorder()
            let backend = AVFoundationCameraCaptureBackend(
                driver: RecordingCaptureDriver(failure: failure),
                diagnosticSink: diagnostics.record
            )

            await #expect(throws: (any Error).self) {
                try await backend.start { _ in }
            }
            #expect(diagnostics.events == [expected])
        }
    }

    @Test("records capture interruptions and runtime termination reasons")
    func recordsRuntimeEvents() async throws {
        let diagnostics = CameraBackendDiagnosticRecorder()
        let driver = RecordingCaptureDriver()
        let backend = AVFoundationCameraCaptureBackend(
            driver: driver,
            diagnosticSink: diagnostics.record
        )
        let run = try await backend.start { _ in }

        await driver.emitEvent(.interrupted(.background))
        await driver.emitEvent(.interruptionEnded)
        await driver.emitEvent(.runtimeError(.mediaServicesWereReset))
        await driver.emitEvent(.runtimeError(.unknown))
        await driver.emitEvent(.unsupportedRuntimeRotation)

        #expect(diagnostics.events == [
            .cameraInterruptedBackground,
            .cameraInterruptionEnded,
            .cameraRuntimeErrorMediaServicesWereReset,
            .cameraRuntimeErrorUnknown,
            .cameraRuntimeRotationUnsupported,
        ])
        await run.stop()
    }

    @Test("starts with a front wide-angle BGRA newest-frame plan")
    func startsWithRequiredPlan() async throws {
        let driver = RecordingCaptureDriver()
        let backend = AVFoundationCameraCaptureBackend(driver: driver)

        let run = try await backend.start { _ in }

        #expect(await driver.lastPlan == .required)
        await run.stop()
    }

    @Test("maps missing front camera and input/output configuration failures to unavailable")
    func mapsUnavailableConfigurationFailures() async {
        for failure in [
            RecordingCaptureDriver.Failure.noFrontCamera,
            .cannotAddInput,
            .cannotAddOutput,
            .unsupportedPixelFormat,
            .unsupportedRotation,
            .cannotGuaranteeNonMirrored
        ] {
            let driver = RecordingCaptureDriver(failure: failure)
            let backend = AVFoundationCameraCaptureBackend(driver: driver)

            await #expect(throws: CameraCaptureBackendError.unavailable) {
                try await backend.start { _ in }
            }

            #expect(await driver.lastPlan == .required)
        }
    }

    @Test("maps unexpected driver failures to failed")
    func mapsUnexpectedFailure() async {
        let driver = RecordingCaptureDriver(failure: .unexpected)
        let backend = AVFoundationCameraCaptureBackend(driver: driver)

        await #expect(throws: CameraCaptureBackendError.failed) {
            try await backend.start { _ in }
        }
    }

    @Test("connection policy disables automatic mirroring then forces non-mirroring")
    func configuresConnectionPolicy() throws {
        var actions: [String] = []
        var mirrored = true

        try AVFoundationCameraConnectionPolicy.configureInitial(
            angle: 90,
            supportsAngle: { $0 == 90 },
            setAngle: { actions.append("angle:\($0)") },
            supportsMirroring: true,
            setAutomaticMirroring: { actions.append("automatic:\($0)") },
            setMirrored: {
                actions.append("mirrored:\($0)")
                mirrored = $0
            },
            isMirrored: { mirrored }
        )

        #expect(actions == ["automatic:false", "mirrored:false", "angle:90.0"])
    }

    @Test("connection policy applies dynamic supported angles")
    func appliesDynamicAngle() throws {
        var applied: [Double] = []

        try AVFoundationCameraConnectionPolicy.applyCaptureAngle(
            180,
            supportsAngle: { $0 == 180 },
            setAngle: { applied.append($0) }
        )

        #expect(applied == [180])
    }

    @Test("connection policy accepts unsupported mirroring when already false")
    func acceptsAlreadyNonMirroredConnection() throws {
        var actions: [String] = []

        try AVFoundationCameraConnectionPolicy.configureInitial(
            angle: 0,
            supportsAngle: { _ in true },
            setAngle: { actions.append("angle:\($0)") },
            supportsMirroring: false,
            setAutomaticMirroring: { actions.append("automatic:\($0)") },
            setMirrored: { actions.append("mirrored:\($0)") },
            isMirrored: { false }
        )

        #expect(actions == ["automatic:false", "angle:0.0"])
    }

    @Test("connection policy fails closed for unsupported angles")
    func rejectsUnsupportedAngle() {
        #expect(throws: AVFoundationCameraConnectionPolicyError.unsupportedRotation) {
            try AVFoundationCameraConnectionPolicy.applyCaptureAngle(
                45,
                supportsAngle: { _ in false },
                setAngle: { _ in Issue.record("unsupported angle was applied") }
            )
        }
    }

    @Test("connection policy fails closed when mirroring cannot be controlled")
    func rejectsUnsupportedMirroring() {
        var actions: [String] = []
        #expect(throws: AVFoundationCameraConnectionPolicyError.cannotGuaranteeNonMirrored) {
            try AVFoundationCameraConnectionPolicy.configureInitial(
                angle: 0,
                supportsAngle: { _ in true },
                setAngle: { _ in Issue.record("angle should not be applied") },
                supportsMirroring: false,
                setAutomaticMirroring: { actions.append("automatic:\($0)") },
                setMirrored: { _ in Issue.record("mirroring should not be changed") },
                isMirrored: { true }
            )
        }
        #expect(actions == ["automatic:false"])
    }

    @Test("connection policy fails closed when final mirroring remains enabled")
    func rejectsFinalMirroringState() {
        #expect(throws: AVFoundationCameraConnectionPolicyError.cannotGuaranteeNonMirrored) {
            try AVFoundationCameraConnectionPolicy.configureInitial(
                angle: 0,
                supportsAngle: { _ in true },
                setAngle: { _ in Issue.record("angle should not be applied") },
                supportsMirroring: true,
                setAutomaticMirroring: { _ in },
                setMirrored: { _ in },
                isMirrored: { true }
            )
        }
    }

    @Test("run stop is idempotent")
    func stopsOnce() async throws {
        let driver = RecordingCaptureDriver()
        let backend = AVFoundationCameraCaptureBackend(driver: driver)
        let run = try await backend.start { _ in }

        await run.stop()
        await run.stop()

        #expect(await driver.stopCallCount == 1)
    }

    @Test("forwards each owned camera frame exactly once unchanged")
    func forwardsOwnedFrame() async throws {
        let driver = RecordingCaptureDriver()
        let backend = AVFoundationCameraCaptureBackend(driver: driver)
        let received = RecordingFrameSink()
        let run = try await backend.start { frame in
            received.append(frame)
        }
        let input = try CameraFrame(
            bytes: Data([1, 2, 3, 4]),
            width: 1,
            height: 1,
            bytesPerRow: 4,
            orientation: .upright
        )

        await driver.emit(input)

        #expect(received.frames == [input])
        await run.stop()
    }

    @Test("copies exact BGRA bytes before temporary native storage changes")
    func copiesFrameBytes() throws {
        let byteCount = 8
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 1)
        defer { pointer.deallocate() }
        for offset in 0..<byteCount {
            pointer.storeBytes(of: UInt8(offset), toByteOffset: offset, as: UInt8.self)
        }
        let temporaryBytes = Data(bytesNoCopy: pointer, count: byteCount, deallocator: .none)

        let frame = try #require(AVFoundationCameraFrameConverter.makeFrame(
            baseAddress: pointer,
            byteCount: temporaryBytes.count,
            width: 1,
            height: 2,
            bytesPerRow: 4,
            pixelFormat: .bgra32
        ))
        pointer.storeBytes(of: UInt8(255), toByteOffset: 0, as: UInt8.self)

        #expect(frame.bytes == Data([0, 1, 2, 3, 4, 5, 6, 7]))
        #expect(frame.width == 1)
        #expect(frame.height == 2)
        #expect(frame.bytesPerRow == 4)
        #expect(frame.orientation == .upright)

    }

    @Test("drops malformed and non-BGRA native buffers before the driver seam")
    func dropsMalformedSamples() {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 1)
        defer { pointer.deallocate() }

        #expect(AVFoundationCameraFrameConverter.makeFrame(
            baseAddress: pointer,
            byteCount: 4,
            width: 0,
            height: 1,
            bytesPerRow: 4,
            pixelFormat: .bgra32
        ) == nil)
        #expect(AVFoundationCameraFrameConverter.makeFrame(
            baseAddress: pointer,
            byteCount: 3,
            width: 1,
            height: 1,
            bytesPerRow: 4,
            pixelFormat: .bgra32
        ) == nil)
        #expect(AVFoundationCameraFrameConverter.makeFrame(
            baseAddress: pointer,
            byteCount: 4,
            width: 1,
            height: 1,
            bytesPerRow: 4,
            pixelFormat: .other
        ) == nil)
    }
}

private final class RecordingFrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CameraFrame] = []

    var frames: [CameraFrame] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ frame: CameraFrame) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(frame)
    }
}

private final class CameraBackendDiagnosticRecorder: @unchecked Sendable {
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

private actor RecordingCaptureDriver: AVFoundationCameraCaptureDriver {
    enum Failure: Error, Equatable, Sendable {
        case noFrontCamera
        case cannotAddInput
        case cannotAddOutput
        case unsupportedPixelFormat
        case unsupportedRotation
        case cannotGuaranteeNonMirrored
        case unexpected
    }

    let failure: Failure?
    private(set) var lastPlan: AVFoundationCameraCapturePlan?
    private(set) var stopCallCount = 0
    private var frameHandler: (@Sendable (CameraFrame) -> Void)?
    private var eventHandler:
        (@Sendable (AVFoundationCameraCaptureDriverEvent) -> Void)?

    init(failure: Failure? = nil) {
        self.failure = failure
    }

    func start(
        plan: AVFoundationCameraCapturePlan,
        frameHandler: @escaping @Sendable (CameraFrame) -> Void,
        eventHandler: @escaping @Sendable
            (AVFoundationCameraCaptureDriverEvent) -> Void
    ) async throws -> any AVFoundationCameraCaptureDriverRun {
        lastPlan = plan
        switch failure {
        case .noFrontCamera:
            throw AVFoundationCameraCaptureDriverError.noFrontCamera
        case .cannotAddInput:
            throw AVFoundationCameraCaptureDriverError.cannotAddInput
        case .cannotAddOutput:
            throw AVFoundationCameraCaptureDriverError.cannotAddOutput
        case .unsupportedPixelFormat:
            throw AVFoundationCameraCaptureDriverError.unsupportedPixelFormat
        case .unsupportedRotation:
            throw AVFoundationCameraCaptureDriverError.unsupportedRotation
        case .cannotGuaranteeNonMirrored:
            throw AVFoundationCameraCaptureDriverError.cannotGuaranteeNonMirrored
        case .unexpected:
            throw AVFoundationCameraCaptureDriverError.unexpected
        case nil:
            self.frameHandler = frameHandler
            self.eventHandler = eventHandler
            return RecordingCaptureRun { [weak self] in
                await self?.incrementStop()
            }
        }
    }

    func emit(_ frame: CameraFrame) {
        frameHandler?(frame)
    }

    func emitEvent(_ event: AVFoundationCameraCaptureDriverEvent) {
        eventHandler?(event)
    }

    private func incrementStop() {
        stopCallCount += 1
    }
}

private actor RecordingCaptureRun: AVFoundationCameraCaptureDriverRun {
    private let stopAction: @Sendable () async -> Void
    private var stopped = false

    init(stopAction: @escaping @Sendable () async -> Void) {
        self.stopAction = stopAction
    }

    func stop() async {
        guard !stopped else {
            return
        }
        stopped = true
        await stopAction()
    }
}
