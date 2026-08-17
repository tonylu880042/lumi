import Foundation

#if os(iOS)
import AVFoundation
#endif

/// AVFoundation-backed camera permission adapter.
///
/// The stored closures are framework-free and make package tests deterministic
/// on macOS. The iOS initializer below is the only place that touches
/// `AVCaptureDevice`; no AVFoundation status or callback type crosses the
/// `CameraPermissionClient` contract.
struct AVFoundationCameraPermissionClient: CameraPermissionClient, Sendable {
    typealias StatusReader = @Sendable () -> CameraPermissionStatus
    typealias AccessRequester =
        @Sendable (@escaping @Sendable (Bool) -> Void) -> Void

    private let statusReader: StatusReader
    private let accessRequester: AccessRequester

    init(
        statusReader: @escaping StatusReader,
        accessRequester: @escaping AccessRequester
    ) {
        self.statusReader = statusReader
        self.accessRequester = accessRequester
    }

    func currentStatus() async -> CameraPermissionStatus {
        statusReader()
    }

    func requestPermission() async -> CameraPermissionStatus {
        await withCheckedContinuation { continuation in
            accessRequester { _ in
                // The completion Bool is only a prompt result. Re-read the
                // authoritative status after completion instead of inferring
                // a grant from that Bool.
                continuation.resume(returning: statusReader())
            }
        }
    }

#if os(iOS)
    /// Creates the production adapter using AVFoundation's video permission.
    init() {
        self.init(
            statusReader: {
                Self.map(
                    AVCaptureDevice.authorizationStatus(for: .video)
                )
            },
            accessRequester: { completion in
                AVCaptureDevice.requestAccess(
                    for: .video,
                    completionHandler: completion
                )
            }
        )
    }

    private static func map(
        _ status: AVAuthorizationStatus
    ) -> CameraPermissionStatus {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            // Do not expose framework-specific future states. A conservative
            // denial is privacy-safe and prevents an unverified camera grant.
            return .denied
        }
    }
#endif
}
