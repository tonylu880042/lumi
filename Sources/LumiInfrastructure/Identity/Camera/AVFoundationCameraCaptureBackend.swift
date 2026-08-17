import Foundation

/// The only camera configuration this PoC backend accepts.
///
/// Keeping the requested device, pixel format, and delivery policy in one
/// value makes the native setup auditable and gives macOS tests a small seam
/// without introducing AVFoundation into package tests.
enum AVFoundationCameraCaptureCamera: Equatable, Sendable {
    case frontBuiltInWideAngle
}

enum AVFoundationCameraCapturePixelFormat: Equatable, Sendable {
    case bgra32
    case other
}

struct AVFoundationCameraCapturePlan: Equatable, Sendable {
    let camera: AVFoundationCameraCaptureCamera
    let pixelFormat: AVFoundationCameraCapturePixelFormat
    let alwaysDiscardsLateVideoFrames: Bool
    let forceNonMirrored: Bool

    static let required = Self(
        camera: .frontBuiltInWideAngle,
        pixelFormat: .bgra32,
        alwaysDiscardsLateVideoFrames: true,
        forceNonMirrored: true
    )
}

/// Errors a concrete AVFoundation driver can classify without exposing
/// framework objects or diagnostics to the camera adapter.
enum AVFoundationCameraCaptureDriverError: Error, Equatable, Sendable {
    case noFrontCamera
    case cannotAddInput
    case cannotAddOutput
    case unsupportedPixelFormat
    case unsupportedRotation
    case cannotGuaranteeNonMirrored
    case unexpected
}

protocol AVFoundationCameraCaptureDriverRun: Sendable {
    func stop() async
}

protocol AVFoundationCameraCaptureDriver: Sendable {
    func start(
        plan: AVFoundationCameraCapturePlan,
        frameHandler: @escaping @Sendable (CameraFrame) -> Void
    ) async throws -> any AVFoundationCameraCaptureDriverRun
}

enum AVFoundationCameraConnectionPolicyError: Error, Equatable, Sendable {
    case unsupportedRotation
    case cannotGuaranteeNonMirrored
}

/// Framework-free decisions for a video connection.
///
/// Native code supplies AVFoundation capability queries and setters. Keeping
/// the ordering and fail-closed checks here lets tests prove the policy on
/// macOS without pretending to reproduce Apple's camera implementation.
enum AVFoundationCameraConnectionPolicy {
    static func configureInitial(
        angle: Double,
        supportsAngle: (Double) -> Bool,
        setAngle: (Double) -> Void,
        supportsMirroring: Bool,
        setAutomaticMirroring: (Bool) -> Void,
        setMirrored: (Bool) -> Void,
        isMirrored: () -> Bool
    ) throws(AVFoundationCameraConnectionPolicyError) {
        // Disable automatic adjustment first. If the connection does not
        // expose a mirroring setter, its existing false state is still safe.
        setAutomaticMirroring(false)

        if supportsMirroring {
            setMirrored(false)
        }

        guard !isMirrored() else {
            throw .cannotGuaranteeNonMirrored
        }
        guard supportsAngle(angle) else {
            throw .unsupportedRotation
        }
        setAngle(angle)
    }

    static func applyCaptureAngle(
        _ angle: Double,
        supportsAngle: (Double) -> Bool,
        setAngle: (Double) -> Void
    ) throws(AVFoundationCameraConnectionPolicyError) {
        guard supportsAngle(angle) else {
            throw .unsupportedRotation
        }
        setAngle(angle)
    }
}

/// Synchronously converts a locked native BGRA buffer to an owned frame.
///
/// The `Data` created here is explicitly non-owning and never escapes this
/// function. `CameraFrame` performs the one owning copy before the function
/// returns, while the caller still holds the pixel-buffer lock.
enum AVFoundationCameraFrameConverter {
    static func makeFrame(
        baseAddress: UnsafeMutableRawPointer?,
        byteCount: Int,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: AVFoundationCameraCapturePixelFormat
    ) -> CameraFrame? {
        guard pixelFormat == .bgra32,
              byteCount > 0,
              let baseAddress
        else {
            return nil
        }

        let temporaryBytes = Data(
            bytesNoCopy: baseAddress,
            count: byteCount,
            deallocator: .none
        )
        return try? CameraFrame(
            bytes: temporaryBytes,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            orientation: .upright
        )
    }
}

/// AVFoundation-backed implementation of the framework-neutral camera port.
///
/// The package-level initializer accepts an injected driver so macOS tests
/// never touch a camera. The parameterless initializer selects the iOS driver
/// and is unavailable on macOS, where it reports `.unavailable` if used.
struct AVFoundationCameraCaptureBackend: CameraCaptureBackend, Sendable {
    private let driver: any AVFoundationCameraCaptureDriver

    init(driver: any AVFoundationCameraCaptureDriver) {
        self.driver = driver
    }

    init() {
#if os(iOS)
        self.driver = AVFoundationNativeCameraCaptureDriver()
#else
        self.driver = AVFoundationUnavailableCameraCaptureDriver()
#endif
    }

    func start(
        frameHandler: @escaping @Sendable (CameraFrame) -> Void
    ) async throws -> any CameraCaptureRun {
        do {
            let nativeRun = try await driver.start(
                plan: .required,
                frameHandler: frameHandler
            )
            return AVFoundationCameraCaptureRun(nativeRun: nativeRun)
        } catch let error as AVFoundationCameraCaptureDriverError {
            throw map(error)
        } catch {
            throw CameraCaptureBackendError.failed
        }
    }

    private func map(
        _ error: AVFoundationCameraCaptureDriverError
    ) -> CameraCaptureBackendError {
        switch error {
        case .noFrontCamera,
             .cannotAddInput,
             .cannotAddOutput,
             .unsupportedPixelFormat,
             .unsupportedRotation,
             .cannotGuaranteeNonMirrored:
            return .unavailable
        case .unexpected:
            return .failed
        }
    }
}

private actor AVFoundationCameraCaptureRun: CameraCaptureRun {
    private let nativeRun: any AVFoundationCameraCaptureDriverRun
    private var didStop = false

    init(nativeRun: any AVFoundationCameraCaptureDriverRun) {
        self.nativeRun = nativeRun
    }

    func stop() async {
        guard !didStop else { return }
        didStop = true
        await nativeRun.stop()
    }
}

private struct AVFoundationUnavailableCameraCaptureDriver:
    AVFoundationCameraCaptureDriver
{
    func start(
        plan: AVFoundationCameraCapturePlan,
        frameHandler: @escaping @Sendable (CameraFrame) -> Void
    ) async throws -> any AVFoundationCameraCaptureDriverRun {
        throw AVFoundationCameraCaptureDriverError.noFrontCamera
    }
}

#if os(iOS)
import AVFoundation
import CoreMedia

/// Serial AVFoundation owner.
///
/// `AVCaptureSession`, its output, the rotation coordinator, KVO token, and
/// delegate are all created and mutated on `sessionQueue`. The native run is
/// the only unchecked-Sendable class: its AVFoundation references and
/// `didStop` flag are queue-confined, while its sample delegate is invoked on
/// that same serial queue.
private struct AVFoundationNativeCameraCaptureDriver:
    AVFoundationCameraCaptureDriver
{
    private let sessionQueue = DispatchQueue(
        label: "com.curves.lumi.camera.capture"
    )

    func start(
        plan: AVFoundationCameraCapturePlan,
        frameHandler: @escaping @Sendable (CameraFrame) -> Void
    ) async throws -> any AVFoundationCameraCaptureDriverRun {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    let run = try AVFoundationNativeCameraCaptureRun(
                        plan: plan,
                        frameHandler: frameHandler,
                        sessionQueue: self.sessionQueue
                    )
                    continuation.resume(returning: run)
                } catch let error as AVFoundationCameraCaptureDriverError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(
                        throwing: AVFoundationCameraCaptureDriverError.unexpected
                    )
                }
            }
        }
    }
}

private final class AVFoundationNativeCameraCaptureRun:
    NSObject,
    AVFoundationCameraCaptureDriverRun,
    @unchecked Sendable
{
    private let sessionQueue: DispatchQueue
    private let session: AVCaptureSession
    private let output: AVCaptureVideoDataOutput
    private let connection: AVCaptureConnection
    private let rotationCoordinator: AVCaptureDevice.RotationCoordinator
    private let sampleDelegate: AVFoundationNativeSampleDelegate
    private var rotationObservation: NSKeyValueObservation?
    private var didStop = false

    init(
        plan: AVFoundationCameraCapturePlan,
        frameHandler: @escaping @Sendable (CameraFrame) -> Void,
        sessionQueue: DispatchQueue
    ) throws {
        self.sessionQueue = sessionQueue
        self.session = AVCaptureSession()

        guard plan.camera == .frontBuiltInWideAngle,
              plan.pixelFormat == .bgra32,
              plan.alwaysDiscardsLateVideoFrames,
              plan.forceNonMirrored
        else {
            throw AVFoundationCameraCaptureDriverError.unexpected
        }

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .front
        ) else {
            throw AVFoundationCameraCaptureDriverError.noFrontCamera
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AVFoundationCameraCaptureDriverError.cannotAddInput
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        guard output.availableVideoPixelFormatTypes.contains(
            kCVPixelFormatType_32BGRA
        ) else {
            throw AVFoundationCameraCaptureDriverError.unsupportedPixelFormat
        }
        // BGRA is the current PoC contract. AVFoundation may convert and
        // allocate for this format; conversion cost and memory footprint are
        // a physical-iPad measurement gate before production use.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_32BGRA)
        ]

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw AVFoundationCameraCaptureDriverError.cannotAddInput
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AVFoundationCameraCaptureDriverError.cannotAddOutput
        }
        session.addOutput(output)

        guard let connection = output.connection(with: .video) else {
            session.commitConfiguration()
            throw AVFoundationCameraCaptureDriverError.cannotAddOutput
        }

        let rotationCoordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: nil
        )
        let initialAngle = Double(
            rotationCoordinator.videoRotationAngleForHorizonLevelCapture
        )
        do {
            try AVFoundationCameraConnectionPolicy.configureInitial(
                angle: initialAngle,
                supportsAngle: {
                    connection.isVideoRotationAngleSupported(CGFloat($0))
                },
                setAngle: {
                    connection.videoRotationAngle = CGFloat($0)
                },
                supportsMirroring: connection.isVideoMirroringSupported,
                setAutomaticMirroring: {
                    connection.automaticallyAdjustsVideoMirroring = $0
                },
                setMirrored: {
                    connection.isVideoMirrored = $0
                },
                isMirrored: {
                    connection.isVideoMirrored
                }
            )
        } catch let error {
            session.commitConfiguration()
            switch error {
            case .unsupportedRotation:
                throw AVFoundationCameraCaptureDriverError.unsupportedRotation
            case .cannotGuaranteeNonMirrored:
                throw AVFoundationCameraCaptureDriverError.cannotGuaranteeNonMirrored
            }
        }
        guard !connection.automaticallyAdjustsVideoMirroring,
              !connection.isVideoMirrored
        else {
            session.commitConfiguration()
            throw AVFoundationCameraCaptureDriverError.cannotGuaranteeNonMirrored
        }

        let sampleDelegate = AVFoundationNativeSampleDelegate(
            frameHandler: frameHandler
        )
        output.setSampleBufferDelegate(sampleDelegate, queue: sessionQueue)
        session.commitConfiguration()

        self.output = output
        self.connection = connection
        self.rotationCoordinator = rotationCoordinator
        self.sampleDelegate = sampleDelegate
        self.rotationObservation = nil
        super.init()

        self.rotationObservation = rotationCoordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.new]
        ) { [weak self] _, _ in
            guard let self else { return }
            self.sessionQueue.async {
                self.applyLatestCaptureAngle()
            }
        }

        session.startRunning()
        guard session.isRunning else {
            rotationObservation?.invalidate()
            rotationObservation = nil
            output.setSampleBufferDelegate(nil, queue: nil)
            throw AVFoundationCameraCaptureDriverError.unexpected
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                guard !self.didStop else {
                    continuation.resume()
                    return
                }
                self.didStop = true
                self.rotationObservation?.invalidate()
                self.rotationObservation = nil
                self.output.setSampleBufferDelegate(nil, queue: nil)
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    private func applyLatestCaptureAngle() {
        guard !didStop else { return }
        let angle = Double(
            rotationCoordinator.videoRotationAngleForHorizonLevelCapture
        )
        do {
            try AVFoundationCameraConnectionPolicy.applyCaptureAngle(
                angle,
                supportsAngle: {
                    connection.isVideoRotationAngleSupported(CGFloat($0))
                },
                setAngle: {
                    connection.videoRotationAngle = CGFloat($0)
                }
            )
        } catch {
            // ponytail: runtime termination cannot yet propagate through
            // CameraCaptureRun; physical rotation validation and a terminal
            // signal seam are required before App wiring.
            // A later unsupported angle cannot be reported through the
            // existing CameraCaptureRun contract. Stop delivery immediately
            // and require a fresh start, rather than emitting stale orientation.
            didStop = true
            rotationObservation?.invalidate()
            rotationObservation = nil
            output.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}

private final class AVFoundationNativeSampleDelegate:
    NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate
{
    private let frameHandler: @Sendable (CameraFrame) -> Void

    init(frameHandler: @escaping @Sendable (CameraFrame) -> Void) {
        self.frameHandler = frameHandler
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetPixelFormatType(pixelBuffer) ==
                kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) ==
                kCVReturnSuccess
        else {
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let (byteCount, overflow) = bytesPerRow.multipliedReportingOverflow(
            by: height
        )
        guard !overflow,
              byteCount > 0,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        else {
            return
        }

        guard let frame = AVFoundationCameraFrameConverter.makeFrame(
            baseAddress: baseAddress,
            byteCount: byteCount,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: .bgra32
        ) else {
            return
        }
        // CameraFrame owns the copied bytes before this callback returns and
        // the pixel-buffer unlock defer executes.
        frameHandler(frame)
    }
}
#endif
