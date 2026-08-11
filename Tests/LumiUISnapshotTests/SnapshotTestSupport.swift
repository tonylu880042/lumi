import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SwiftUI
import XCTest
import LumiPresentation
import LumiUI

enum SnapshotMatrix: String, CaseIterable {
    case baseStates = "base-states"
    case events
    case audioAndAccessibility = "audio-accessibility"
    case primitivesAndThemes = "primitives-themes"

    var baselineFileName: String { rawValue + ".png" }
}

enum SnapshotTheme: Equatable {
    case light
    case lavender
    case dark

    var background: Color {
        switch self {
        case .light: Color.white
        case .lavender: Color(red: 0.957, green: 0.925, blue: 0.980)
        case .dark: Color(red: 0.075, green: 0.055, blue: 0.12)
        }
    }

    var labelBackground: Color {
        switch self {
        case .dark: Color(red: 0.13, green: 0.10, blue: 0.20)
        case .light, .lavender: Color(red: 0.96, green: 0.95, blue: 0.97)
        }
    }

    var labelForeground: Color {
        switch self {
        case .dark: Color.white
        case .light, .lavender: Color(red: 0.13, green: 0.10, blue: 0.20)
        }
    }
}

struct SnapshotTile: Identifiable {
    let label: String
    let state: AvatarVisualState
    let theme: SnapshotTheme

    var id: String { label }
}

private enum SnapshotLayout {
    static let columns = 4
    static let tileWidth: CGFloat = 240
    static let avatarHeight: CGFloat = 158
    static let labelHeight: CGFloat = 32
    static let tileHeight = avatarHeight + labelHeight
    static let scale: CGFloat = 2
}

private struct SnapshotMatrixView: View {
    let tiles: [SnapshotTile]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tiles.chunked(into: SnapshotLayout.columns).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(row) { tile in
                        SnapshotTileView(tile: tile)
                    }
                    if row.count < SnapshotLayout.columns {
                        ForEach(row.count ..< SnapshotLayout.columns, id: \.self) { _ in
                            Color.clear
                                .frame(width: SnapshotLayout.tileWidth, height: SnapshotLayout.tileHeight)
                        }
                    }
                }
            }
        }
        .background(Color.white)
    }
}

private struct SnapshotTileView: View {
    let tile: SnapshotTile

    var body: some View {
        VStack(spacing: 0) {
            LumiAvatarView(state: tile.state)
                .frame(width: SnapshotLayout.tileWidth, height: SnapshotLayout.avatarHeight)
                .background(tile.theme.background)
            Text(tile.label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .frame(width: SnapshotLayout.tileWidth, height: SnapshotLayout.labelHeight)
                .foregroundStyle(tile.theme.labelForeground)
                .background(tile.theme.labelBackground)
        }
        .frame(width: SnapshotLayout.tileWidth, height: SnapshotLayout.tileHeight)
        .overlay(Rectangle().stroke(Color.black.opacity(0.08), lineWidth: 1))
    }
}

@MainActor
enum SnapshotVerifier {
    static func verify(_ matrix: SnapshotMatrix, tiles: [SnapshotTile], filePath: String = #filePath) throws {
        let rendered = try render(tiles: tiles)
        let baselineURL = baselineURL(for: matrix, filePath: filePath)
        if ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1" {
            try writePNG(rendered, to: baselineURL)
            return
        }

        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            XCTFail(
                "\(matrix.rawValue): approved baseline missing at \(baselineURL.path). " +
                    "Run RECORD_SNAPSHOTS=1 swift test --filter LumiUISnapshotTests.\(testName(for: matrix)) to record it."
            )
            return
        }

        let expected = try PixelImage(url: baselineURL)
        let actual = try PixelImage(image: rendered)
        guard expected.width == actual.width, expected.height == actual.height else {
            XCTFail(
                "\(matrix.rawValue): snapshot dimensions changed (expected " +
                    "\(expected.width)x\(expected.height), actual \(actual.width)x\(actual.height))"
            )
            return
        }
        let comparison = expected.compare(with: actual)
        guard !comparison.hasDifferences else {
            let diffURL = try writeDiff(expected: expected, actual: actual, matrix: matrix)
            XCTFail(
                "\(matrix.rawValue): pixel regression (\(comparison.differentPixels)/\(comparison.pixelCount) " +
                    "pixels differ; max channel delta \(comparison.maxChannelDelta); " +
                    "allowed delta \(PixelImage.allowedChannelDelta), allowed pixels \(comparison.allowedPixels)). " +
                    "Diff: \(diffURL.path)"
            )
            return
        }
    }

    private static func render(tiles: [SnapshotTile]) throws -> CGImage {
        let rows = max(1, Int(ceil(Double(tiles.count) / Double(SnapshotLayout.columns))))
        let width = SnapshotLayout.tileWidth * CGFloat(SnapshotLayout.columns)
        let height = SnapshotLayout.tileHeight * CGFloat(rows)
        let view = SnapshotMatrixView(tiles: tiles)
            .frame(width: width, height: height)

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.scale = SnapshotLayout.scale
        renderer.isOpaque = true
        guard let image = renderer.cgImage else {
            throw SnapshotError.renderingFailed
        }
        let expectedWidth = Int(width * SnapshotLayout.scale)
        let expectedHeight = Int(height * SnapshotLayout.scale)
        guard image.width == expectedWidth, image.height == expectedHeight else {
            throw SnapshotError.unexpectedSize(
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: image.width,
                actualHeight: image.height
            )
        }
        return image
    }

    private static func baselineURL(for matrix: SnapshotMatrix, filePath: String) -> URL {
        if let override = ProcessInfo.processInfo.environment["SNAPSHOT_BASELINE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent(matrix.baselineFileName)
        }
        return URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(matrix.baselineFileName)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw SnapshotError.encodingFailed(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SnapshotError.encodingFailed(url)
        }
    }

    private static func writeDiff(expected: PixelImage, actual: PixelImage, matrix: SnapshotMatrix) throws -> URL {
        guard expected.width == actual.width, expected.height == actual.height else {
            throw SnapshotError.unexpectedSize(
                expectedWidth: expected.width,
                expectedHeight: expected.height,
                actualWidth: actual.width,
                actualHeight: actual.height
            )
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-snapshot-diff-\(matrix.rawValue).png")
        var bytes = [UInt8](repeating: 0, count: expected.data.count)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let different = (0 ..< 3).contains { channel in
                abs(Int(expected.data[index + channel]) - Int(actual.data[index + channel])) > PixelImage.allowedChannelDelta
            }
            if different {
                bytes[index] = 255
                bytes[index + 1] = 0
                bytes[index + 2] = 0
                bytes[index + 3] = 255
            } else {
                let luminance = UInt8((Int(actual.data[index]) + Int(actual.data[index + 1]) + Int(actual.data[index + 2])) / 3)
                bytes[index] = luminance
                bytes[index + 1] = luminance
                bytes[index + 2] = luminance
                bytes[index + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &bytes,
            width: expected.width,
            height: expected.height,
            bitsPerComponent: 8,
            bytesPerRow: expected.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw SnapshotError.encodingFailed(url)
        }
        try writePNG(image, to: url)
        return url
    }

    private static func testName(for matrix: SnapshotMatrix) -> String {
        switch matrix {
        case .baseStates: "testBaseStatesMatrix"
        case .events: "testEventSemanticsMatrix"
        case .audioAndAccessibility: "testAudioAndReducedMotionMatrix"
        case .primitivesAndThemes: "testVisualPrimitivesAndThemesMatrix"
        }
    }
}

private enum SnapshotError: Error, CustomStringConvertible {
    case renderingFailed
    case rasterizationFailed
    case encodingFailed(URL)
    case unexpectedSize(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)

    var description: String {
        switch self {
        case .renderingFailed: "ImageRenderer returned no CGImage"
        case .rasterizationFailed: "Unable to rasterize CGImage into RGBA pixels"
        case .encodingFailed(let url): "Unable to encode PNG at \(url.path)"
        case .unexpectedSize(let ew, let eh, let aw, let ah):
            "Expected image size \(ew)x\(eh), got \(aw)x\(ah)"
        }
    }
}

private struct PixelImage {
    static let allowedChannelDelta = 2
    let width: Int
    let height: Int
    let data: [UInt8]

    init(image: CGImage) throws {
        self.width = image.width
        self.height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw SnapshotError.rasterizationFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.data = bytes
    }

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SnapshotError.encodingFailed(url)
        }
        try self.init(image: image)
    }

    func compare(with other: PixelImage) -> PixelComparison {
        guard width == other.width, height == other.height else {
            return PixelComparison(
                differentPixels: width * height,
                pixelCount: width * height,
                maxChannelDelta: 255,
                allowedPixels: 0
            )
        }
        var differentPixels = 0
        var maxChannelDelta = 0
        for index in stride(from: 0, to: data.count, by: 4) {
            var pixelDifferent = false
            for channel in 0 ..< 4 {
                let delta = abs(Int(data[index + channel]) - Int(other.data[index + channel]))
                maxChannelDelta = max(maxChannelDelta, delta)
                if channel < 3, delta > Self.allowedChannelDelta {
                    pixelDifferent = true
                }
            }
            if pixelDifferent { differentPixels += 1 }
        }
        return PixelComparison(
            differentPixels: differentPixels,
            pixelCount: width * height,
            maxChannelDelta: maxChannelDelta,
            allowedPixels: max(8, (width * height) / 10_000)
        )
    }
}

private struct PixelComparison {
    let differentPixels: Int
    let pixelCount: Int
    let maxChannelDelta: Int
    let allowedPixels: Int

    var hasDifferences: Bool {
        differentPixels > allowedPixels
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start ..< Swift.min(start + size, count)])
        }
    }
}

extension AvatarEventCommand {
    static var allCases: [AvatarEventCommand] {
        [.playful, .memberRecognized, .firstVisit, .longTimeNoSee, .goalAchieved, .weeklyGoalCompleted, .error]
    }

    var snapshotLabel: String {
        switch self {
        case .playful: "playful"
        case .memberRecognized: "member-recognized"
        case .firstVisit: "first-visit"
        case .longTimeNoSee: "long-time-no-see"
        case .goalAchieved: "goal-achieved"
        case .weeklyGoalCompleted: "weekly-goal-completed"
        case .error: "error"
        }
    }
}
