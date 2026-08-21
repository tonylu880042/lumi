#if DEBUG

import Foundation
import CoreGraphics
import ImageIO
@testable import LumiApplication
import UniformTypeIdentifiers
@testable import LumiInfrastructure
import Testing

@Suite("Identity calibration photo frame decoder")
struct IdentityCalibrationPhotoFrameDecoderTests {
    @Test("corrupt imported data fails closed and balances security scope")
    func corruptDataClosesSecurityScope() async throws {
        let scope = RecordingSecurityScope()
        let decoder = ImageIOIdentityCalibrationPhotoFrameDecoder(scope: scope)
        let url = try temporaryURL(extension: "jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)

        await #expect(throws: IdentityCalibrationError.failed) {
            _ = try await decoder.frame(from: url)
        }

        #expect(await scope.startURLs == [url])
        #expect(await scope.stopURLs == [url])
    }

    @Test("encoded Data photo decodes without security scope")
    func encodedDataPhotoDecodesWithoutSecurityScope() async throws {
        let scope = RecordingSecurityScope()
        let decoder = ImageIOIdentityCalibrationPhotoFrameDecoder(scope: scope)
        let url = try temporaryURL(extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        try PhotoFixture.writeImage(to: url, type: .png)
        let payload = IdentityCalibrationPhoto(data: try Data(contentsOf: url))

        let frame = try await decoder.frame(from: payload)

        #expect(frame.width == 3)
        #expect(frame.height == 2)
        #expect(frame.orientation == .upright)
        #expect(await scope.startURLs.isEmpty)
        #expect(await scope.stopURLs.isEmpty)
    }

    @Test("unsupported file type fails closed without leaking framework details")
    func unsupportedFileTypeFailsClosed() async throws {
        let scope = RecordingSecurityScope()
        let decoder = ImageIOIdentityCalibrationPhotoFrameDecoder(scope: scope)
        let url = try temporaryURL(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x47, 0x49, 0x46, 0x38]).write(to: url)

        await #expect(throws: IdentityCalibrationError.failed) {
            _ = try await decoder.frame(from: url)
        }
        #expect(await scope.startURLs == [url])
        #expect(await scope.stopURLs == [url])
    }

    @Test("source UTI, not the filename suffix, controls acceptance")
    func sourceUTIControlsAcceptance() async throws {
        let scope = RecordingSecurityScope()
        let decoder = ImageIOIdentityCalibrationPhotoFrameDecoder(scope: scope)
        let url = try temporaryURL(extension: "jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try PhotoFixture.writeImage(to: url, type: .png)

        let frame = try await decoder.frame(from: url)
        #expect(frame.width == 3)
        #expect(frame.height == 2)
        #expect(await scope.stopURLs == [url])
        acceptsSendable(decoder)
    }

    @Test("accepts exactly JPEG PNG and HEIC source types")
    func acceptsApprovedSourceTypes() async throws {
        let approved: [(UTType, String)] = [
            (.jpeg, "jpg"),
            (.png, "png"),
            (.heic, "heic")
        ]

        for (type, fileExtension) in approved {
            let scope = RecordingSecurityScope()
            let decoder = ImageIOIdentityCalibrationPhotoFrameDecoder(scope: scope)
            let url = try temporaryURL(extension: fileExtension)
            defer { try? FileManager.default.removeItem(at: url) }
            try PhotoFixture.writeImage(to: url, type: type)

            let frame = try await decoder.frame(from: url)
            #expect(frame.width == 3)
            #expect(frame.height == 2)
            #expect(frame.orientation == .upright)
            #expect(await scope.startURLs == [url])
            #expect(await scope.stopURLs == [url])
        }
    }

    @Test("rejects GIF, TIFF, corrupt, and multi-image sources")
    func rejectsUnsupportedCorruptAndMultiImageSources() async throws {
        let cases: [(UTType?, String, Data?)] = [
            (.gif, "gif", nil),
            (.tiff, "tiff", nil),
            (nil, "jpg", Data([0x00, 0x01, 0x02, 0x03]))
        ]

        for (type, fileExtension, corruptData) in cases {
            let scope = RecordingSecurityScope()
            let decoder = ImageIOIdentityCalibrationPhotoFrameDecoder(scope: scope)
            let url = try temporaryURL(extension: fileExtension)
            defer { try? FileManager.default.removeItem(at: url) }
            if let corruptData {
                try corruptData.write(to: url)
            } else if let type {
                try PhotoFixture.writeImage(to: url, type: type)
            }

            await #expect(throws: IdentityCalibrationError.failed) {
                _ = try await decoder.frame(from: url)
            }
            #expect(await scope.stopURLs == [url])
        }

        let scope = RecordingSecurityScope()
        let decoder = ImageIOIdentityCalibrationPhotoFrameDecoder(scope: scope)
        let multiImageURL = try temporaryURL(extension: "heic")
        defer { try? FileManager.default.removeItem(at: multiImageURL) }
        try PhotoFixture.writeImage(to: multiImageURL, type: .heic, imageCount: 2)

        await #expect(throws: IdentityCalibrationError.failed) {
            _ = try await decoder.frame(from: multiImageURL)
        }
        #expect(await scope.stopURLs == [multiImageURL])
    }

    @Test("applies every EXIF orientation to an asymmetric source")
    func appliesAllEXIFOrientations() async throws {
        let expected: [UInt32: [[UInt8]]] = [
            1: [[1, 2, 3], [4, 5, 6]],
            2: [[3, 2, 1], [6, 5, 4]],
            3: [[6, 5, 4], [3, 2, 1]],
            4: [[4, 5, 6], [1, 2, 3]],
            5: [[1, 4], [2, 5], [3, 6]],
            6: [[4, 1], [5, 2], [6, 3]],
            7: [[6, 3], [5, 2], [4, 1]],
            8: [[3, 6], [2, 5], [1, 4]]
        ]

        for orientation in UInt32(1) ... UInt32(8) {
            let scope = RecordingSecurityScope()
            let decoder = ImageIOIdentityCalibrationPhotoFrameDecoder(scope: scope)
            let url = try temporaryURL(extension: "png")
            defer { try? FileManager.default.removeItem(at: url) }
            try PhotoFixture.writeImage(
                to: url,
                type: .png,
                orientation: orientation
            )

            let frame = try await decoder.frame(from: url)
            let expectedRows = try #require(expected[orientation])
            #expect(frame.width == expectedRows[0].count)
            #expect(frame.height == expectedRows.count)
            #expect(frame.orientation == .upright)
            #expect(frame.bytesPerRow >= frame.width * 4)
            #expect(frame.bytesPerRow.isMultiple(of: 64))
            #expect(pixelIDs(in: frame) == expectedRows)
            #expect(allPixelsHaveExpectedBGRA(in: frame))
        }
    }

    @Test("downsamples large sources to the explicit DEBUG bound")
    func downsamplesLargeSource() async throws {
        let scope = RecordingSecurityScope()
        let decoder = ImageIOIdentityCalibrationPhotoFrameDecoder(scope: scope)
        let url = try temporaryURL(extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        try PhotoFixture.writeLargeImage(to: url)

        let frame = try await decoder.frame(from: url)

        #expect(frame.width == ImageIOIdentityCalibrationPhotoFrameDecoder.maximumPixelSize)
        #expect(frame.height == 1)
        #expect(frame.width <= ImageIOIdentityCalibrationPhotoFrameDecoder.maximumPixelSize)
        #expect(frame.bytesPerRow >= frame.width * 4)
        #expect(frame.bytesPerRow.isMultiple(of: 64))
    }

    @Test("security scope denial fails closed without an unbalanced stop")
    func deniedSecurityScopeFailsClosed() async throws {
        let scope = RecordingSecurityScope(allowsAccess: false)
        let decoder = ImageIOIdentityCalibrationPhotoFrameDecoder(scope: scope)
        let url = try temporaryURL(extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        try PhotoFixture.writeImage(to: url, type: .png)

        await #expect(throws: IdentityCalibrationError.failed) {
            _ = try await decoder.frame(from: url)
        }
        #expect(await scope.startURLs == [url])
        #expect(await scope.stopURLs.isEmpty)
    }

    @Test("cancellation after scope access preserves cancellation and closes scope")
    func cancellationBalancesSecurityScope() async throws {
        let scope = RecordingSecurityScope(suspendStart: true)
        let decoder = ImageIOIdentityCalibrationPhotoFrameDecoder(scope: scope)
        let url = try temporaryURL(extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        try PhotoFixture.writeImage(to: url, type: .png)

        let task = Task {
            try await decoder.frame(from: url)
        }
        await scope.waitForStart()
        task.cancel()
        await scope.releaseStart()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await scope.startURLs == [url])
        #expect(await scope.stopURLs == [url])
    }

    @Test("decoder exposes the approved DEBUG thumbnail bound")
    func thumbnailBoundIsExplicit() {
        #expect(ImageIOIdentityCalibrationPhotoFrameDecoder.maximumPixelSize == 2_048)
        acceptsSendable(IdentityCalibrationError.failed)
    }

    private func temporaryURL(extension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-calibration-\(UUID().uuidString)")
            .appendingPathExtension(`extension`)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw IdentityCalibrationError.failed
        }
        return url
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}

private func pixelIDs(in frame: CameraFrame) -> [[UInt8]] {
    (0 ..< frame.height).map { row in
        (0 ..< frame.width).map { column in
            frame.bytes[row * frame.bytesPerRow + column * 4]
        }
    }
}

private func allPixelsHaveExpectedBGRA(in frame: CameraFrame) -> Bool {
    for row in 0 ..< frame.height {
        for column in 0 ..< frame.width {
            let offset = row * frame.bytesPerRow + column * 4
            guard frame.bytes[offset + 1] == 0,
                  frame.bytes[offset + 2] == 0,
                  frame.bytes[offset + 3] == 255
            else {
                return false
            }
        }
    }
    return true
}

private enum PhotoFixture {
    static func writeImage(
        to url: URL,
        type: UTType,
        orientation: UInt32 = 1,
        imageCount: Int = 1
    ) throws {
        guard let image = makeImage(width: 3, height: 2),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  type.identifier as CFString,
                  imageCount,
                  nil
              )
        else {
            throw IdentityCalibrationError.failed
        }

        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: NSNumber(value: orientation)
        ]
        for _ in 0 ..< imageCount {
            CGImageDestinationAddImage(
                destination,
                image,
                properties as CFDictionary
            )
        }
        guard CGImageDestinationFinalize(destination) else {
            throw IdentityCalibrationError.failed
        }
    }

    static func writeLargeImage(to url: URL) throws {
        guard let image = makeImage(width: 4_096, height: 1),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              )
        else {
            throw IdentityCalibrationError.failed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw IdentityCalibrationError.failed
        }
    }

    private static func makeImage(width: Int, height: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let offset = (row * width + column) * 4
                let id: UInt8
                if width == 3, height == 2 {
                    id = UInt8(row * width + column + 1)
                } else {
                    id = UInt8((column % 6) + 1)
                }
                bytes[offset] = 0
                bytes[offset + 1] = 0
                bytes[offset + 2] = id
                bytes[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

private actor RecordingSecurityScope: IdentityCalibrationSecurityScope {
    private let allowsAccess: Bool
    private let suspendStart: Bool
    private var pendingStart: CheckedContinuation<Void, Never>?
    private var startStarted = AsyncStream<Void>.makeStream(
        of: Void.self,
        bufferingPolicy: .bufferingNewest(1)
    )
    private(set) var startURLs: [URL] = []
    private(set) var stopURLs: [URL] = []

    init(allowsAccess: Bool = true, suspendStart: Bool = false) {
        self.allowsAccess = allowsAccess
        self.suspendStart = suspendStart
    }

    func startAccessing(_ url: URL) async -> Bool {
        startURLs.append(url)
        if suspendStart {
            startStarted.continuation.yield(())
            await withCheckedContinuation { continuation in
                pendingStart = continuation
            }
        }
        return allowsAccess
    }

    func stopAccessing(_ url: URL) async {
        stopURLs.append(url)
    }

    func waitForStart() async {
        var iterator = startStarted.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func releaseStart() {
        pendingStart?.resume()
        pendingStart = nil
    }
}

#endif
