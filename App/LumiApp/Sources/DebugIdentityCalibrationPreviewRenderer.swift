#if DEBUG

import CoreGraphics
import Foundation
import LumiPresentation

/// App-only bridge from the Presentation preview value to a display image.
///
/// This renderer validates all geometry before asking Core Graphics to create
/// an image. It preserves the camera's BGRA byte order, padded stride, and
/// top-left orientation while treating the fourth byte as skipped/opaque;
/// display mirroring belongs to SwiftUI only.
enum DebugIdentityCalibrationPreviewRenderer {
    static func makeImage(
        from frame: DebugIdentityCalibrationPreviewFrame
    ) -> CGImage? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let minimumBytesPerRowResult = frame.width.multipliedReportingOverflow(by: 4)
        guard !minimumBytesPerRowResult.overflow,
              frame.bytesPerRow >= minimumBytesPerRowResult.partialValue else {
            return nil
        }
        let requiredByteCountResult = frame.bytesPerRow
            .multipliedReportingOverflow(by: frame.height)
        guard !requiredByteCountResult.overflow,
              frame.bgraBytes.count >= requiredByteCountResult.partialValue else {
            return nil
        }

        guard let provider = CGDataProvider(data: frame.bgraBytes as CFData) else {
            return nil
        }

        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )

        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

#endif
