import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("SFace alignment cropper")
struct SFaceAlignmentCropperTests {
    @Test("canonical reference landmarks preserve an identity-sized frame")
    func canonicalReferenceLandmarksPreserveIdentityPixels() throws {
        let frame = try makeFrame(width: 112, height: 112, bytesPerRow: 112 * 4) {
            let blue = UInt8(($0 * 3 + $1) & 0xFF)
            let green = UInt8(($1 * 5 + $0) & 0xFF)
            let red = UInt8(($0 + $1 * 7) & 0xFF)
            return [blue, green, red, 255]
        }
        let landmarks = try canonicalLandmarks(
            sourceWidth: frame.width,
            sourceHeight: frame.height
        )

        let output = try SFaceAlignmentCropper().crop(
            frame: frame,
            landmarks: landmarks
        )

        #expect(output.width == 112)
        #expect(output.height == 112)
        #expect(output.bytesPerRow == 112 * 4)
        #expect(output.bytes.count == 112 * 112 * 4)

        for (x, y) in [(0, 0), (17, 29), (56, 71), (111, 111)] {
            let expected = sourcePixel(x: x, y: y)
            let actual = try #require(output.pixel(x: x, y: y))
            for channel in 0..<4 {
                #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= 1)
            }
        }
    }

    @Test("integer translation uses top-left raster coordinates and zero border")
    func integerTranslationUsesBlackBorder() throws {
        let frame = try makeFrame(width: 112, height: 112, bytesPerRow: 112 * 4) {
            [UInt8($0), UInt8($1), 91, 255]
        }
        let landmarks = try translatedCanonicalLandmarks(
            sourceWidth: frame.width,
            sourceHeight: frame.height,
            translationX: 2,
            translationY: 1
        )

        let output = try SFaceAlignmentCropper().crop(
            frame: frame,
            landmarks: landmarks
        )

        #expect(try output.pixel(x: 0, y: 0) == [2, 1, 91, 255])
        #expect(try output.pixel(x: 109, y: 110) == [111, 111, 91, 255])
        #expect(try output.pixel(x: 110, y: 111) == [0, 0, 0, 0])
        #expect(try output.pixel(x: 111, y: 111) == [0, 0, 0, 0])
    }

    @Test("rotation and scale preserve nontrivial inverse-mapped pixels")
    func rotationAndScaleUseSimilarityTerms() throws {
        let bytesPerRow = 112 * 4 + 13
        let frame = try makeFrame(width: 112, height: 112, bytesPerRow: bytesPerRow) {
            [
                UInt8($0 + $1),
                UInt8($0),
                UInt8($1),
                255
            ]
        }
        let scale = 0.9
        let angle = 0.18
        let landmarks = try rotatedScaledCanonicalLandmarks(
            sourceWidth: frame.width,
            sourceHeight: frame.height,
            scale: scale,
            angle: angle
        )

        let output = try SFaceAlignmentCropper().crop(
            frame: frame,
            landmarks: landmarks
        )

        let center = (x: 56.0262, y: 71.9008)
        for (x, y) in [(45, 61), (56, 72), (68, 84)] {
            let source = inverseMap(
                destinationX: Double(x),
                destinationY: Double(y),
                center: center,
                scale: scale,
                angle: angle
            )
            let expected = [
                UInt8((source.x + source.y).rounded()),
                UInt8(source.x.rounded()),
                UInt8(source.y.rounded()),
                255
            ]
            let actual = try #require(output.pixel(x: x, y: y))
            for channel in 0..<4 {
                #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= 1)
            }
        }
    }

    @Test("resampling respects a nontrivial source row stride")
    func respectsPaddedSourceStride() throws {
        let bytesPerRow = 112 * 4 + 13
        let frame = try makeFrame(width: 112, height: 112, bytesPerRow: bytesPerRow) {
            [UInt8(($0 * 11) & 0xFF), UInt8(($1 * 13) & 0xFF), 37, 255]
        }
        let landmarks = try canonicalLandmarks(
            sourceWidth: frame.width,
            sourceHeight: frame.height
        )

        let output = try SFaceAlignmentCropper().crop(
            frame: frame,
            landmarks: landmarks
        )

        #expect(try output.pixel(x: 4, y: 7) == [44, 91, 37, 255])
        #expect(try output.pixel(x: 111, y: 111) == [197, 163, 37, 255])
    }

    @Test("identical landmarks fail closed with a redacted error")
    func degenerateLandmarksFailClosed() throws {
        let frame = try makeFrame(width: 112, height: 112, bytesPerRow: 112 * 4) {
            _, _ in
            [0, 0, 0, 255]
        }
        let point = try NormalizedPoint(x: 0.5, y: 0.5)
        let landmarks = try SFaceAlignmentLandmarks(
            points: Dictionary(uniqueKeysWithValues: SFaceAlignmentLandmarkRole.allCases.map {
                ($0, point)
            })
        )

        #expect(throws: SFaceAlignmentCropperError.failed) {
            try SFaceAlignmentCropper().crop(frame: frame, landmarks: landmarks)
        }
    }

    @Test("error and output values are fixed, equatable, sendable, and redacted")
    func valuesAreStableAndSendable() throws {
        let first = try makeFrame(width: 112, height: 112, bytesPerRow: 112 * 4) {
            _, _ in
            [17, 31, 47, 255]
        }
        let landmarks = try canonicalLandmarks(
            sourceWidth: first.width,
            sourceHeight: first.height
        )
        let cropper = SFaceAlignmentCropper()
        let output = try cropper.crop(frame: first, landmarks: landmarks)
        let second = try cropper.crop(frame: first, landmarks: landmarks)

        #expect(output == second)
        acceptsSendable(cropper)
        acceptsSendable(output)

        let error = SFaceAlignmentCropperError.failed
        #expect(String(describing: error) == "SFace alignment crop failed.")
        #expect(String(reflecting: error) == "SFace alignment crop failed.")
        #expect(Mirror(reflecting: error).children.isEmpty)
        acceptsSendable(error)
    }

    private func canonicalLandmarks(
        sourceWidth: Int,
        sourceHeight: Int
    ) throws -> SFaceAlignmentLandmarks {
        let points = [
            (38.2946, 51.6963),
            (73.5318, 51.5014),
            (56.0252, 71.7366),
            (41.5493, 92.3655),
            (70.7299, 92.2041)
        ]
        let roles = SFaceAlignmentLandmarkRole.allCases
        let values = try zip(roles, points).map { role, point in
            (
                role,
                try NormalizedPoint(
                    x: point.0 / Double(sourceWidth),
                    y: 1 - point.1 / Double(sourceHeight)
                )
            )
        }
        return try SFaceAlignmentLandmarks(
            points: Dictionary(uniqueKeysWithValues: values)
        )
    }

    private func translatedCanonicalLandmarks(
        sourceWidth: Int,
        sourceHeight: Int,
        translationX: Double,
        translationY: Double
    ) throws -> SFaceAlignmentLandmarks {
        let points = [
            (38.2946 + translationX, 51.6963 + translationY),
            (73.5318 + translationX, 51.5014 + translationY),
            (56.0252 + translationX, 71.7366 + translationY),
            (41.5493 + translationX, 92.3655 + translationY),
            (70.7299 + translationX, 92.2041 + translationY)
        ]
        let roles = SFaceAlignmentLandmarkRole.allCases
        let values = try zip(roles, points).map { role, point in
            (
                role,
                try NormalizedPoint(
                    x: point.0 / Double(sourceWidth),
                    y: 1 - point.1 / Double(sourceHeight)
                )
            )
        }
        return try SFaceAlignmentLandmarks(
            points: Dictionary(uniqueKeysWithValues: values)
        )
    }

    private func rotatedScaledCanonicalLandmarks(
        sourceWidth: Int,
        sourceHeight: Int,
        scale: Double,
        angle: Double
    ) throws -> SFaceAlignmentLandmarks {
        let center = (x: 56.0262, y: 71.9008)
        let destination = [
            (38.2946, 51.6963),
            (73.5318, 51.5014),
            (56.0252, 71.7366),
            (41.5493, 92.3655),
            (70.7299, 92.2041)
        ]
        let values = try zip(SFaceAlignmentLandmarkRole.allCases, destination).map {
            role,
            point in
            let source = inverseMap(
                destinationX: point.0,
                destinationY: point.1,
                center: center,
                scale: scale,
                angle: angle
            )
            return (
                role,
                try NormalizedPoint(
                    x: source.x / Double(sourceWidth),
                    y: 1 - source.y / Double(sourceHeight)
                )
            )
        }
        return try SFaceAlignmentLandmarks(
            points: Dictionary(uniqueKeysWithValues: values)
        )
    }

    private func makeFrame(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixel: (Int, Int) -> [UInt8]
    ) throws -> CameraFrame {
        var bytes = Array(repeating: UInt8(0xD3), count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let values = pixel(x, y)
                for channel in 0..<4 {
                    bytes[offset + channel] = values[channel]
                }
            }
        }
        return try CameraFrame(
            bytes: Data(bytes),
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            orientation: .upright
        )
    }

    private func sourcePixel(x: Int, y: Int) -> [UInt8] {
        [
            UInt8((x * 3 + y) & 0xFF),
            UInt8((y * 5 + x) & 0xFF),
            UInt8((x + y * 7) & 0xFF),
            255
        ]
    }

    private func inverseMap(
        destinationX: Double,
        destinationY: Double,
        center: (x: Double, y: Double),
        scale: Double,
        angle: Double
    ) -> (x: Double, y: Double) {
        let cosine = cos(angle)
        let sine = sin(angle)
        let dx = (destinationX - center.x) / scale
        let dy = (destinationY - center.y) / scale
        return (
            center.x + cosine * dx + sine * dy,
            center.y - sine * dx + cosine * dy
        )
    }
}

private extension SFaceAlignedFace {
    func pixel(x: Int, y: Int) -> [UInt8]? {
        guard (0..<width).contains(x), (0..<height).contains(y) else {
            return nil
        }
        let offset = y * bytesPerRow + x * 4
        guard offset >= 0, offset + 4 <= bytes.count else {
            return nil
        }
        return Array(bytes[offset..<(offset + 4)])
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
