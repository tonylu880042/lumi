#if DEBUG

import CoreGraphics
import Foundation
import ImageIO
import LumiApplication
import UniformTypeIdentifiers

/// Async seam for the security-scoped resource lifetime. The concrete
/// implementation wraps Foundation's URL methods; tests can prove balanced
/// access without touching a document picker.
protocol IdentityCalibrationSecurityScope: Sendable {
    func startAccessing(_ url: URL) async -> Bool
    func stopAccessing(_ url: URL) async
}

struct SystemIdentityCalibrationSecurityScope:
    IdentityCalibrationSecurityScope,
    Sendable
{
    func startAccessing(_ url: URL) async -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) async {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Internal image-to-frame seam. A URL and its decoded pixels remain inside
/// Infrastructure; only the owned, framework-free `CameraFrame` escapes.
protocol IdentityCalibrationPhotoFrameSource: Sendable {
    func frame(from imageURL: URL) async throws -> CameraFrame
}

/// Decodes one user-selected image into the camera frame contract.
///
/// ImageIO owns EXIF rotation/mirroring and thumbnail downsampling. The
/// resulting context is explicitly top-left and little-endian BGRA8 with a
/// padded row stride, matching the native camera converter's contract.
actor ImageIOIdentityCalibrationPhotoFrameDecoder:
    IdentityCalibrationPhotoFrameSource
{
    static let maximumPixelSize = 2_048

    private static let allowedTypes: [UTType] = [.jpeg, .png, .heic]

    private let scope: any IdentityCalibrationSecurityScope

    init(
        scope: any IdentityCalibrationSecurityScope =
            SystemIdentityCalibrationSecurityScope()
    ) {
        self.scope = scope
    }

    func frame(from imageURL: URL) async throws -> CameraFrame {
        try Task.checkCancellation()
        guard await scope.startAccessing(imageURL) else {
            try Task.checkCancellation()
            throw IdentityCalibrationError.failed
        }

        do {
            try Task.checkCancellation()
            let frame = try decode(imageURL: imageURL)
            try Task.checkCancellation()
            await scope.stopAccessing(imageURL)
            return frame
        } catch let cancellation as CancellationError {
            await scope.stopAccessing(imageURL)
            throw cancellation
        } catch {
            await scope.stopAccessing(imageURL)
            throw IdentityCalibrationError.failed
        }
    }

    private func decode(imageURL: URL) throws -> CameraFrame {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let sourceTypeIdentifier = CGImageSourceGetType(source),
              let sourceType = UTType(sourceTypeIdentifier as String),
              Self.allowedTypes.contains(where: {
                  sourceType == $0 || sourceType.conforms(to: $0)
              }),
              CGImageSourceGetCount(source) == 1
        else {
            throw IdentityCalibrationError.failed
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: kCFBooleanTrue as Any,
            kCGImageSourceThumbnailMaxPixelSize:
                NSNumber(value: Self.maximumPixelSize),
            kCGImageSourceCreateThumbnailWithTransform: kCFBooleanTrue as Any
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw IdentityCalibrationError.failed
        }

        let width = image.width
        let height = image.height
        guard width > 0,
              height > 0,
              width <= Self.maximumPixelSize,
              height <= Self.maximumPixelSize
        else {
            throw IdentityCalibrationError.failed
        }

        let minimumRowBytes = width.multipliedReportingOverflow(by: 4)
        guard !minimumRowBytes.overflow else {
            throw IdentityCalibrationError.failed
        }
        let roundedRowBytes = minimumRowBytes.partialValue
            .addingReportingOverflow(63)
        guard !roundedRowBytes.overflow else {
            throw IdentityCalibrationError.failed
        }
        let bytesPerRow = (roundedRowBytes.partialValue / 64) * 64
        let storageSize = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !storageSize.overflow else {
            throw IdentityCalibrationError.failed
        }

        var bytes = Data(count: storageSize.partialValue)
        let rendered = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue:
                          CGImageAlphaInfo.premultipliedFirst.rawValue
                              | CGBitmapInfo.byteOrder32Little.rawValue
                      ).rawValue
                  )
            else {
                return false
            }

            // Core Graphics writes bitmap row zero at the beginning of the
            // caller-owned buffer. Keep that row as the visual top so the
            // CameraFrame remains top-left after ImageIO's EXIF transform.
            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(width),
                    height: CGFloat(height)
                )
            )
            return true
        }
        guard rendered else {
            throw IdentityCalibrationError.failed
        }

        do {
            return try CameraFrame(
                bytes: bytes,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                orientation: .upright
            )
        } catch {
            throw IdentityCalibrationError.failed
        }
    }
}

#endif
