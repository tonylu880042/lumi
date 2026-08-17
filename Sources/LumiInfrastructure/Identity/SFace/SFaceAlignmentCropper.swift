import Foundation

/// Stable, payload-free failures at the SFace alignment boundary.
enum SFaceAlignmentCropperError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case failed

    var description: String { "SFace alignment crop failed." }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}

/// The owned, framework-neutral result of SFace's five-point alignment.
///
/// Pixels are top-left-origin, row-major BGRA8 bytes. Keeping the camera's
/// BGRA layout here deliberately defers alpha removal and BGR/RGB graph-order
/// selection to the later SFace inference adapter.
struct SFaceAlignedFace: Equatable, Sendable {
    static let outputWidth = 112
    static let outputHeight = 112
    static let outputBytesPerRow = outputWidth * 4

    let bytes: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int

    fileprivate init(bytes: Data) {
        self.bytes = bytes
        self.width = Self.outputWidth
        self.height = Self.outputHeight
        self.bytesPerRow = Self.outputBytesPerRow
    }
}

/// Pure five-point SFace alignment and 112×112 crop.
///
/// This is a source-equivalent continuous implementation of OpenCV Zoo's
/// pinned `FaceRecognizerSF.alignCrop` geometry. It uses OpenCV's reference
/// points and an analytic 2×2 Procrustes solution numerically equivalent to
/// the source's SVD for full-rank landmark sets. Sampling follows the
/// `warpAffine(..., INTER_LINEAR)` inverse map with a zero constant border;
/// byte-for-byte parity with OpenCV's fixed-point interpolation tables remains
/// a real-model/fixture validation gate for the next integration slice.
struct SFaceAlignmentCropper: Sendable {
    private static let destinationPoints: [(x: Double, y: Double)] = [
        (38.2946, 51.6963),
        (73.5318, 51.5014),
        (56.0252, 71.7366),
        (41.5493, 92.3655),
        (70.7299, 92.2041)
    ]

    // OpenCV 4.10.0 uses these rounded destination means in its source.
    private static let destinationMean = (x: 56.0262, y: 71.9008)

    init() {}

    func crop(
        frame: CameraFrame,
        landmarks: SFaceAlignmentLandmarks
    ) throws(SFaceAlignmentCropperError) -> SFaceAlignedFace {
        do {
            let sourcePoints = try Self.sourcePoints(
                landmarks: landmarks,
                width: frame.width,
                height: frame.height
            )
            let transform = try Self.similarityTransform(sourcePoints)
            let bytes = try Self.render(frame: frame, transform: transform)
            return SFaceAlignedFace(bytes: bytes)
        } catch {
            throw .failed
        }
    }

    private struct AffineTransform: Sendable {
        let a: Double
        let b: Double
        let c: Double
        let d: Double
        let tx: Double
        let ty: Double
    }

    private static func sourcePoints(
        landmarks: SFaceAlignmentLandmarks,
        width: Int,
        height: Int
    ) throws(SFaceAlignmentCropperError) -> [(x: Double, y: Double)] {
        guard width > 0, height > 0,
              let widthValue = Double(exactly: width),
              let heightValue = Double(exactly: height),
              widthValue.isFinite, heightValue.isFinite else {
            throw .failed
        }

        let points = landmarks.openCVAlignCropOrder.map { point in
            (
                x: point.x * widthValue,
                y: (1 - point.y) * heightValue
            )
        }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw .failed
        }
        return points
    }

    private static func similarityTransform(
        _ source: [(x: Double, y: Double)]
    ) throws(SFaceAlignmentCropperError) -> AffineTransform {
        guard source.count == destinationPoints.count else {
            throw .failed
        }

        let sourceMean = (
            x: source.reduce(0) { $0 + $1.x } / 5,
            y: source.reduce(0) { $0 + $1.y } / 5
        )
        guard sourceMean.x.isFinite, sourceMean.y.isFinite else {
            throw .failed
        }

        var denominator = 0.0
        var alphaNumerator = 0.0
        var betaNumerator = 0.0
        for (src, dst) in zip(source, destinationPoints) {
            let srcX = src.x - sourceMean.x
            let srcY = src.y - sourceMean.y
            let dstX = dst.x - destinationMean.x
            let dstY = dst.y - destinationMean.y
            denominator += srcX * srcX + srcY * srcY
            alphaNumerator += dstX * srcX + dstY * srcY
            betaNumerator += dstY * srcX - dstX * srcY
        }
        guard denominator.isFinite, alphaNumerator.isFinite,
              betaNumerator.isFinite, denominator > 1e-12 else {
            throw .failed
        }

        // A proper 2D similarity has matrix [[alpha, -beta], [beta, alpha]].
        // These constrained least-squares coefficients are the analytic
        // full-rank equivalent of OpenCV's U·D·Vᵀ SVD result; reflections are
        // not introduced because the fitted transform is restricted to proper
        // rotation plus uniform scale.
        let alpha = alphaNumerator / denominator
        let beta = betaNumerator / denominator
        let determinant = alpha * alpha + beta * beta
        guard alpha.isFinite, beta.isFinite,
              determinant.isFinite, determinant > 1e-24 else {
            throw .failed
        }

        let translation = (
            x: destinationMean.x - (alpha * sourceMean.x
                - beta * sourceMean.y),
            y: destinationMean.y - (beta * sourceMean.x
                + alpha * sourceMean.y)
        )
        guard translation.x.isFinite, translation.y.isFinite else {
            throw .failed
        }

        return AffineTransform(
            a: alpha,
            b: -beta,
            c: beta,
            d: alpha,
            tx: translation.x,
            ty: translation.y
        )
    }

    private static func render(
        frame: CameraFrame,
        transform: AffineTransform
    ) throws(SFaceAlignmentCropperError) -> Data {
        let determinant = transform.a * transform.d
            - transform.b * transform.c
        guard determinant.isFinite, abs(determinant) > 1e-12 else {
            throw .failed
        }

        let inverse = (
            a: transform.d / determinant,
            b: -transform.b / determinant,
            c: -transform.c / determinant,
            d: transform.a / determinant
        )
        guard [inverse.a, inverse.b, inverse.c, inverse.d]
            .allSatisfy(\.isFinite) else {
            throw .failed
        }

        var output = Array(
            repeating: UInt8.zero,
            count: SFaceAlignedFace.outputHeight
                * SFaceAlignedFace.outputBytesPerRow
        )

        do {
            try frame.bytes.withUnsafeBytes { sourceRawBuffer in
                guard sourceRawBuffer.baseAddress != nil else {
                    throw SFaceAlignmentCropperError.failed
                }

                for destinationY in 0..<SFaceAlignedFace.outputHeight {
                    for destinationX in 0..<SFaceAlignedFace.outputWidth {
                        let deltaX = Double(destinationX) - transform.tx
                        let deltaY = Double(destinationY) - transform.ty
                        let sourceX = inverse.a * deltaX + inverse.b * deltaY
                        let sourceY = inverse.c * deltaX + inverse.d * deltaY
                        guard sourceX.isFinite, sourceY.isFinite else {
                            throw SFaceAlignmentCropperError.failed
                        }

                        let outputOffset = destinationY
                            * SFaceAlignedFace.outputBytesPerRow + destinationX * 4
                        Self.writeBilinearPixel(
                            sourceX: sourceX,
                            sourceY: sourceY,
                            frame: frame,
                            sourceRawBuffer: sourceRawBuffer,
                            output: &output,
                            outputOffset: outputOffset
                        )
                    }
                }
            }
        } catch {
            throw .failed
        }
        return Data(output)
    }

    private static func writeBilinearPixel(
        sourceX: Double,
        sourceY: Double,
        frame: CameraFrame,
        sourceRawBuffer: UnsafeRawBufferPointer,
        output: inout [UInt8],
        outputOffset: Int
    ) {
        // Coordinates wholly outside the one-pixel interpolation halo cannot
        // contribute anything but the zero constant border. Returning before
        // converting to Int also keeps extreme finite affine results fail
        // closed instead of trapping on an unrepresentable conversion.
        guard sourceX >= -1, sourceX < Double(frame.width),
              sourceY >= -1, sourceY < Double(frame.height) else {
            return
        }
        let floorX = sourceX.rounded(.down)
        let floorY = sourceY.rounded(.down)
        let x0 = Int(floorX)
        let y0 = Int(floorY)
        let xWeight = sourceX - floorX
        let yWeight = sourceY - floorY

        for channel in 0..<4 {
            let topLeft = sourceByte(
                x: x0,
                y: y0,
                channel: channel,
                frame: frame,
                sourceRawBuffer: sourceRawBuffer
            )
            let topRight = sourceByte(
                x: x0 + 1,
                y: y0,
                channel: channel,
                frame: frame,
                sourceRawBuffer: sourceRawBuffer
            )
            let bottomLeft = sourceByte(
                x: x0,
                y: y0 + 1,
                channel: channel,
                frame: frame,
                sourceRawBuffer: sourceRawBuffer
            )
            let bottomRight = sourceByte(
                x: x0 + 1,
                y: y0 + 1,
                channel: channel,
                frame: frame,
                sourceRawBuffer: sourceRawBuffer
            )
            let top = Double(topLeft) * (1 - xWeight)
                + Double(topRight) * xWeight
            let bottom = Double(bottomLeft) * (1 - xWeight)
                + Double(bottomRight) * xWeight
            let value = top * (1 - yWeight) + bottom * yWeight
            output[outputOffset + channel] = UInt8(
                max(0, min(255, value.rounded()))
            )
        }
    }

    private static func sourceByte(
        x: Int,
        y: Int,
        channel: Int,
        frame: CameraFrame,
        sourceRawBuffer: UnsafeRawBufferPointer
    ) -> UInt8 {
        guard x >= 0, x < frame.width, y >= 0, y < frame.height,
              channel >= 0, channel < 4 else {
            return 0
        }
        let (rowOffset, rowOverflow) = y.multipliedReportingOverflow(
            by: frame.bytesPerRow
        )
        let (pixelOffset, pixelOverflow) = x.multipliedReportingOverflow(by: 4)
        let (baseOffset, offsetOverflow) = rowOffset.addingReportingOverflow(pixelOffset)
        let (offset, channelOverflow) = baseOffset.addingReportingOverflow(channel)
        guard !rowOverflow, !pixelOverflow, !offsetOverflow,
              !channelOverflow,
              offset >= 0, offset <= sourceRawBuffer.count,
              sourceRawBuffer.count - offset >= 1 else {
            return 0
        }
        return sourceRawBuffer.load(fromByteOffset: offset, as: UInt8.self)
    }
}
