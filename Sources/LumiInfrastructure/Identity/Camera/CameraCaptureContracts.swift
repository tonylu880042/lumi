import Foundation

/// Framework-neutral camera permission states.
///
/// The Apple authorization enum is deliberately translated at the future
/// adapter boundary and never crosses this contract.
enum CameraPermissionStatus: Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

/// Stable permission failures exposed by the camera seam.
enum CameraPermissionError: Error, Equatable, Sendable {
    case denied
    case restricted
}

/// Injectable permission boundary used by camera capture.
protocol CameraPermissionClient: Sendable {
    func currentStatus() async -> CameraPermissionStatus
    func requestPermission() async -> CameraPermissionStatus
}

extension CameraPermissionClient {
    /// Authorizes capture without leaking framework-specific status details.
    ///
    /// A request is made only for `notDetermined`. Cancellation is checked at
    /// each boundary so a caller receives `CancellationError` unchanged.
    func authorize() async throws {
        try Task.checkCancellation()

        switch await currentStatus() {
        case .authorized:
            try Task.checkCancellation()
        case .denied:
            throw CameraPermissionError.denied
        case .restricted:
            throw CameraPermissionError.restricted
        case .notDetermined:
            try Task.checkCancellation()
            let requestedStatus = await requestPermission()
            try Task.checkCancellation()

            switch requestedStatus {
            case .authorized:
                return
            case .restricted:
                throw CameraPermissionError.restricted
            case .denied, .notDetermined:
                // A request that does not grant access cannot start capture.
                // Keep the public failure surface deliberately small.
                throw CameraPermissionError.denied
            }
        }
    }
}

/// Orientation carried by an owned camera frame.
///
/// Camera pixels crossing this boundary are already horizon-level and
/// non-mirrored. Downstream Vision must use `.up` and must not rotate the
/// frame again.
enum CameraFrameOrientation: CaseIterable, Equatable, Sendable {
    case upright
}
