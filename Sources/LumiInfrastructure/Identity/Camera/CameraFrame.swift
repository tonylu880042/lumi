import Foundation

/// Validation failures for an owned camera frame.
///
/// The errors intentionally expose only stable technical categories. They do
/// not contain dimensions, byte counts, or framework payloads.
enum CameraFrameError: Error, Equatable, Sendable {
    case nonPositiveDimensions
    case invalidRowStride
    case insufficientBytes
}

/// An immutable, framework-neutral BGRA frame owned by Infrastructure.
///
/// The initializer copies the required byte range synchronously while the
/// caller still owns its source buffer. No platform image or sample-buffer
/// type crosses this value boundary. Its pixels are already upright and
/// non-mirrored; Vision must consume them with `.up` without another rotation.
struct CameraFrame: Equatable, Sendable {
    let bytes: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let orientation: CameraFrameOrientation

    init(
        bytes: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        orientation: CameraFrameOrientation
    ) throws(CameraFrameError) {
        guard width > 0, height > 0 else {
            throw .nonPositiveDimensions
        }

        let (minimumBytesPerRow, rowWidthOverflow) =
            width.multipliedReportingOverflow(by: 4)
        guard !rowWidthOverflow, bytesPerRow >= minimumBytesPerRow else {
            throw .invalidRowStride
        }

        let (requiredBytes, storageOverflow) =
            bytesPerRow.multipliedReportingOverflow(by: height)
        guard !storageOverflow, bytes.count >= requiredBytes else {
            throw .insufficientBytes
        }

        // `Data(bytes:count:)` allocates and copies immediately. Keeping it
        // inside the source's `withUnsafeBytes` scope makes it impossible for
        // the owned value to retain a pointer into the caller's storage.
        let ownedBytes: Data
        do {
            ownedBytes = try bytes.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    throw CameraFrameError.insufficientBytes
                }
                return Data(bytes: baseAddress, count: requiredBytes)
            }
        } catch let error as CameraFrameError {
            throw error
        } catch {
            // Foundation should not throw here, but keep the contract's
            // privacy-safe error surface closed if a future implementation
            // does.
            throw .insufficientBytes
        }

        self.bytes = ownedBytes
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.orientation = orientation
    }
}
