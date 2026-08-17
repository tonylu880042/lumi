import Accelerate
import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("YuNet vImage preprocessor")
struct YuNetVImagePreprocessorTests {
    @Test("returns the exact BGR NCHW shape and the 37A transform")
    func returnsExpectedShapeAndTransform() throws {
        let frame = try makeFrame(width: 3, height: 2, bytesPerRow: 16)
        let preprocessor = YuNetVImagePreprocessor()

        let output = try preprocessor.preprocess(frame: frame)
        let expectedTransform = try YuNetLetterboxTransform(
            sourceWidth: frame.width,
            sourceHeight: frame.height
        )

        #expect(YuNetVImagePreprocessorOutput.shape == [1, 3, 640, 640])
        #expect(output.values.count == 1_228_800)
        #expect(output.transform == expectedTransform)
        acceptsSendable(output)
    }

    @Test("uses default Lanczos-3 through explicit no-flags vImage scaling")
    func pinsDefaultLanczosThree() throws {
        let frame = try makeFrame(width: 3, height: 2, bytesPerRow: 16)
        let transform = try YuNetLetterboxTransform(
            sourceWidth: frame.width,
            sourceHeight: frame.height
        )
        let noFlagsCanvas = try referenceCanvas(
            frame: frame,
            transform: transform,
            flags: vImage_Flags(kvImageNoFlags)
        )
        let highQualityCanvas = try referenceCanvas(
            frame: frame,
            transform: transform,
            flags: vImage_Flags(kvImageHighQualityResampling)
        )
        #expect(noFlagsCanvas != highQualityCanvas)

        let output = try YuNetVImagePreprocessor().preprocess(frame: frame)
        #expect(output.values == nchwValues(from: noFlagsCanvas))
        #expect(output.values != nchwValues(from: highQualityCanvas))
    }

    @Test("preserves BGRA stride, ignores alpha, and leaves asymmetric black padding")
    func preservesStrideAndBlackPadding() throws {
        let frame = try makeFrame(width: 3, height: 2, bytesPerRow: 16)
        let transform = try YuNetLetterboxTransform(
            sourceWidth: frame.width,
            sourceHeight: frame.height
        )
        let expectedCanvas = try referenceCanvas(
            frame: frame,
            transform: transform,
            flags: vImage_Flags(kvImageNoFlags)
        )
        let output = try YuNetVImagePreprocessor().preprocess(frame: frame)

        #expect(output.values == nchwValues(from: expectedCanvas))
        #expect(transform.topPadding == 106)
        #expect(transform.bottomPadding == 107)
        #expect(canvasRowIsZero(expectedCanvas, row: 0))
        #expect(canvasRowIsZero(expectedCanvas, row: transform.topPadding - 1))
        #expect(!canvasRowIsZero(expectedCanvas, row: transform.topPadding))
        #expect(
            canvasRowIsZero(
                expectedCanvas,
                row: transform.topPadding + transform.scaledHeight
            )
        )
        #expect(canvasRowIsZero(expectedCanvas, row: 639))
    }

    @Test("ignores alpha bytes while preserving BGR values exactly")
    func ignoresAlphaBytes() throws {
        let frame = try makeFrame(width: 3, height: 2, bytesPerRow: 16)
        var alphaChangedBytes = Array(frame.bytes)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                alphaChangedBytes[y * frame.bytesPerRow + x * 4 + 3] ^= 0xFF
            }
        }
        let alphaChangedFrame = try CameraFrame(
            bytes: Data(alphaChangedBytes),
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            orientation: .upright
        )

        let preprocessor = YuNetVImagePreprocessor()
        let originalOutput = try preprocessor.preprocess(frame: frame)
        let alphaChangedOutput = try preprocessor.preprocess(frame: alphaChangedFrame)

        #expect(originalOutput.values == alphaChangedOutput.values)
    }

    @Test("places portrait content between left and right black padding")
    func placesPortraitContentWithHorizontalPadding() throws {
        let frame = try makeFrame(width: 2, height: 3, bytesPerRow: 12)
        let transform = try YuNetLetterboxTransform(
            sourceWidth: frame.width,
            sourceHeight: frame.height
        )
        let expectedCanvas = try referenceCanvas(
            frame: frame,
            transform: transform,
            flags: vImage_Flags(kvImageNoFlags)
        )
        let output = try YuNetVImagePreprocessor().preprocess(frame: frame)

        #expect(output.values == nchwValues(from: expectedCanvas))
        #expect(transform.leftPadding == 106)
        #expect(transform.rightPadding == 107)
        #expect(canvasColumnIsZero(expectedCanvas, column: 0))
        #expect(canvasColumnIsZero(expectedCanvas, column: transform.leftPadding - 1))
        #expect(!canvasColumnIsZero(expectedCanvas, column: transform.leftPadding))
        #expect(
            canvasColumnIsZero(
                expectedCanvas,
                column: transform.leftPadding + transform.scaledWidth
            )
        )
        #expect(canvasColumnIsZero(expectedCanvas, column: 639))
    }

    @Test("redacts the single typed failure and keeps it Sendable")
    func redactsFailure() {
        let error = YuNetVImagePreprocessorError.failed

        #expect(String(describing: error) == "YuNet vImage preprocessing failed.")
        #expect(String(reflecting: error) == "YuNet vImage preprocessing failed.")
        #expect(Mirror(reflecting: error).children.isEmpty)
        #expect(!String(reflecting: error).contains("640"))
        #expect(!String(reflecting: error).contains("vImage_Error"))
        acceptsSendable(error)
    }

    private func makeFrame(
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws -> CameraFrame {
        var bytes = Array(repeating: UInt8(0xE7), count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * bytesPerRow + x * 4
                bytes[index] = UInt8(10 + x * 41 + y * 13)
                bytes[index + 1] = UInt8(40 + x * 17 + y * 29)
                bytes[index + 2] = UInt8(80 + x * 23 + y * 37)
                bytes[index + 3] = UInt8(120 + x * 19 + y * 31)
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

    private func referenceCanvas(
        frame: CameraFrame,
        transform: YuNetLetterboxTransform,
        flags: vImage_Flags
    ) throws -> [UInt8] {
        let canvasRowBytes = 640 * 4
        var canvas = Array(repeating: UInt8.zero, count: canvasRowBytes * 640)
        let error = try frame.bytes.withUnsafeBytes { sourceRawBuffer in
            try canvas.withUnsafeMutableBytes { destinationRawBuffer in
                guard let sourceBaseAddress = sourceRawBuffer.baseAddress,
                      let destinationBaseAddress = destinationRawBuffer.baseAddress
                else {
                    throw ReferenceError.missingBuffer
                }

                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBaseAddress),
                    height: vImagePixelCount(frame.height),
                    width: vImagePixelCount(frame.width),
                    rowBytes: frame.bytesPerRow
                )
                let contentOffset = transform.topPadding * canvasRowBytes
                    + transform.leftPadding * 4
                var destination = vImage_Buffer(
                    data: destinationBaseAddress.advanced(by: contentOffset),
                    height: vImagePixelCount(transform.scaledHeight),
                    width: vImagePixelCount(transform.scaledWidth),
                    rowBytes: canvasRowBytes
                )
                return vImageScale_ARGB8888(
                    &source,
                    &destination,
                    nil,
                    flags
                )
            }
        }
        guard error == kvImageNoError else {
            throw ReferenceError.vImageFailure
        }
        return canvas
    }

    private func nchwValues(from canvas: [UInt8]) -> [Float] {
        let planeSize = 640 * 640
        var values = Array(repeating: Float.zero, count: planeSize * 3)
        for y in 0..<640 {
            for x in 0..<640 {
                let pixelOffset = (y * 640 + x) * 4
                let planeOffset = y * 640 + x
                values[planeOffset] = Float(canvas[pixelOffset])
                values[planeSize + planeOffset] = Float(canvas[pixelOffset + 1])
                values[planeSize * 2 + planeOffset] = Float(canvas[pixelOffset + 2])
            }
        }
        return values
    }

    private func canvasRowIsZero(_ canvas: [UInt8], row: Int) -> Bool {
        let start = row * 640 * 4
        return canvas[start..<(start + 640 * 4)].allSatisfy { $0 == 0 }
    }

    private func canvasColumnIsZero(_ canvas: [UInt8], column: Int) -> Bool {
        for row in 0..<640 {
            let offset = (row * 640 + column) * 4
            if canvas[offset] != 0
                || canvas[offset + 1] != 0
                || canvas[offset + 2] != 0
                || canvas[offset + 3] != 0 {
                return false
            }
        }
        return true
    }
}

private enum ReferenceError: Error {
    case missingBuffer
    case vImageFailure
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
