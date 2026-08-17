import Accelerate
import Foundation

/// Stable, payload-free failures at the YuNet pixel preprocessing boundary.
///
/// Camera frames crossing this boundary are already validated, owned BGRA,
/// upright, and non-mirrored. Any failure in the geometry or vImage contract
/// is intentionally redacted to this one case.
enum YuNetVImagePreprocessorError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case failed

    var description: String { "YuNet vImage preprocessing failed." }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}

/// The fixed BGR NCHW tensor emitted for YuNet's 640×640 input canvas.
struct YuNetVImagePreprocessorOutput: Equatable, Sendable {
    static let shape = [
        1,
        3,
        YuNetLetterboxTransform.targetDimension,
        YuNetLetterboxTransform.targetDimension
    ]

    let values: [Float]
    let transform: YuNetLetterboxTransform
}

/// Aspect-fits an owned camera frame onto a black 640×640 canvas with vImage.
///
/// `vImageScale_ARGB8888` is used for BGRA bytes as documented by vImage. Its
/// default Lanczos-3 resampling is selected explicitly with `kvImageNoFlags`;
/// no high-quality flag or configurable resampling seam is exposed here.
struct YuNetVImagePreprocessor: Sendable {
    static let targetDimension = YuNetLetterboxTransform.targetDimension

    init() {}

    func preprocess(
        frame: CameraFrame
    ) throws(YuNetVImagePreprocessorError) -> YuNetVImagePreprocessorOutput {
        do {
            let transform = try YuNetLetterboxTransform(
                sourceWidth: frame.width,
                sourceHeight: frame.height
            )

            var canvas = Array(
                repeating: UInt8.zero,
                count: Self.targetDimension * Self.targetDimension * 4
            )

            try frame.bytes.withUnsafeBytes { sourceRawBuffer in
                try canvas.withUnsafeMutableBytes { destinationRawBuffer in
                    guard let sourceBaseAddress = sourceRawBuffer.baseAddress,
                          let destinationBaseAddress = destinationRawBuffer.baseAddress
                    else {
                        throw YuNetVImagePreprocessorError.failed
                    }

                    var source = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: sourceBaseAddress),
                        height: vImagePixelCount(frame.height),
                        width: vImagePixelCount(frame.width),
                        rowBytes: frame.bytesPerRow
                    )
                    let canvasRowBytes = Self.targetDimension * 4
                    let contentOffset = transform.topPadding * canvasRowBytes
                        + transform.leftPadding * 4
                    var destination = vImage_Buffer(
                        data: destinationBaseAddress.advanced(by: contentOffset),
                        height: vImagePixelCount(transform.scaledHeight),
                        width: vImagePixelCount(transform.scaledWidth),
                        rowBytes: canvasRowBytes
                    )

                    let status = vImageScale_ARGB8888(
                        &source,
                        &destination,
                        nil,
                        vImage_Flags(kvImageNoFlags)
                    )
                    guard status == kvImageNoError else {
                        throw YuNetVImagePreprocessorError.failed
                    }
                }
            }

            let values = try Self.nchwValues(from: canvas)
            return YuNetVImagePreprocessorOutput(
                values: values,
                transform: transform
            )
        } catch {
            throw .failed
        }
    }

    private static func nchwValues(
        from canvas: [UInt8]
    ) throws(YuNetVImagePreprocessorError) -> [Float] {
        let planeSize = targetDimension * targetDimension
        let expectedByteCount = planeSize * 4
        guard canvas.count == expectedByteCount else {
            throw .failed
        }

        var values = Array(repeating: Float.zero, count: planeSize * 3)
        for row in 0..<targetDimension {
            for column in 0..<targetDimension {
                let pixelOffset = (row * targetDimension + column) * 4
                let planeOffset = row * targetDimension + column
                values[planeOffset] = Float(canvas[pixelOffset])
                values[planeSize + planeOffset] = Float(canvas[pixelOffset + 1])
                values[planeSize * 2 + planeOffset] = Float(canvas[pixelOffset + 2])
            }
        }
        return values
    }
}
