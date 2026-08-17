import Foundation

/// The fixed, framework-neutral failure returned when Vision cannot produce a
/// trustworthy face-rectangle result.
enum VisionFaceDetectorError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case failed

    var description: String { "Vision face detection failed." }
}

/// Raw values crossing the testable Vision-provider seam.
///
/// The values intentionally remain unvalidated here. The detector validates
/// the complete provider result before returning any `DetectedFace`, so a
/// malformed framework observation fails the call rather than yielding a
/// misleading partial list.
struct VisionFaceObservationValues: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Double

    init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        confidence: Double
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.confidence = confidence
    }
}

/// SDK-free boundary around one native Vision request.
protocol VisionFaceObservationProvider: Sendable {
    func detect(
        frame: CameraFrame
    ) async throws -> [VisionFaceObservationValues]
}

/// Infrastructure-owned face rectangle detector.
///
/// It maps every valid provider observation in provider order. Selection,
/// confidence thresholds, quality gates, and landmark inference belong to
/// later layers and are deliberately absent here.
struct VisionFaceDetector: Sendable {
    private let provider: any VisionFaceObservationProvider

    init(provider: any VisionFaceObservationProvider) {
        self.provider = provider
    }

    init() {
#if os(iOS)
        self.provider = NativeVisionFaceObservationProvider()
#else
        self.provider = UnavailableVisionFaceObservationProvider()
#endif
    }

    func detect(frame: CameraFrame) async throws -> [DetectedFace] {
        try Task.checkCancellation()

        do {
            let observations = try await provider.detect(frame: frame)
            try Task.checkCancellation()

            var faces: [DetectedFace] = []
            faces.reserveCapacity(observations.count)
            for observation in observations {
                guard let face = Self.makeFace(from: observation) else {
                    throw VisionFaceDetectorError.failed
                }
                faces.append(face)
            }
            return faces
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // If cancellation raced a provider's non-cancellation failure,
            // preserve the caller's cancellation rather than redacting it.
            if Task.isCancelled {
                throw CancellationError()
            }
            throw VisionFaceDetectorError.failed
        }
    }

    private static func makeFace(
        from observation: VisionFaceObservationValues
    ) -> DetectedFace? {
        guard let boundingBox = try? NormalizedRect(
            x: observation.x,
            y: observation.y,
            width: observation.width,
            height: observation.height
        ) else {
            return nil
        }

        return try? DetectedFace(
            boundingBox: boundingBox,
            confidence: observation.confidence,
            alignmentLandmarks: nil
        )
    }
}

private struct UnavailableVisionFaceObservationProvider:
    VisionFaceObservationProvider
{
    func detect(
        frame: CameraFrame
    ) async throws -> [VisionFaceObservationValues] {
        _ = frame
        throw VisionFaceDetectorError.failed
    }
}

#if os(iOS)
import CoreGraphics
import ImageIO
import Vision

/// Actor-isolated native Vision owner.
///
/// Each call creates a fresh image, request, and handler on the actor's
/// non-main executor. Native framework references never cross the provider
/// seam; only copied scalar observation values do.
private actor NativeVisionFaceObservationProvider:
    VisionFaceObservationProvider
{
    func detect(
        frame: CameraFrame
    ) async throws -> [VisionFaceObservationValues] {
        try Task.checkCancellation()

        guard frame.orientation == .upright else {
            throw VisionFaceDetectorError.failed
        }

        // `CameraFrame` owns immutable 32BGRA bytes. With byteOrder32Little,
        // premultipliedFirst maps the camera's [B, G, R, A] bytes to the
        // Core Graphics device-RGB image without repacking or cropping.
        guard let dataProvider = CGDataProvider(data: frame.bytes as CFData),
              let image = CGImage(
                  width: frame.width,
                  height: frame.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: frame.bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue:
                      CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue
                  ),
                  provider: dataProvider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw VisionFaceDetectorError.failed
        }

        try Task.checkCancellation()

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cgImage: image,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw VisionFaceDetectorError.failed
        }

        try Task.checkCancellation()

        return (request.results ?? []).map { observation in
            let boundingBox = observation.boundingBox
            return VisionFaceObservationValues(
                x: Double(boundingBox.origin.x),
                y: Double(boundingBox.origin.y),
                width: Double(boundingBox.size.width),
                height: Double(boundingBox.size.height),
                confidence: Double(observation.confidence)
            )
        }
    }
}
#endif
