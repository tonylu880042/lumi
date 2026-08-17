import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("YuNet letterbox transform")
struct YuNetLetterboxTransformTests {
    @Test("keeps a square frame at 640 with no padding")
    func squareFrameHasNoPadding() throws {
        let transform = try YuNetLetterboxTransform(
            sourceWidth: 640,
            sourceHeight: 640
        )

        #expect(transform.scaledWidth == 640)
        #expect(transform.scaledHeight == 640)
        #expect(transform.leftPadding == 0)
        #expect(transform.topPadding == 0)
        #expect(transform.rightPadding == 0)
        #expect(transform.bottomPadding == 0)

        let point = try NormalizedPoint(x: 0.25, y: 0.75)
        #expect(try transform.unmap(point: point) == point)
    }

    @Test("fits a 4:3 landscape frame with symmetric vertical padding")
    func landscapeFrameUsesAspectFit() throws {
        let transform = try YuNetLetterboxTransform(
            sourceWidth: 400,
            sourceHeight: 300
        )

        #expect(transform.scaledWidth == 640)
        #expect(transform.scaledHeight == 480)
        #expect(transform.leftPadding == 0)
        #expect(transform.rightPadding == 0)
        #expect(transform.topPadding == 80)
        #expect(transform.bottomPadding == 80)
    }

    @Test("fits a portrait frame with symmetric horizontal padding")
    func portraitFrameUsesAspectFit() throws {
        let transform = try YuNetLetterboxTransform(
            sourceWidth: 300,
            sourceHeight: 400
        )

        #expect(transform.scaledWidth == 480)
        #expect(transform.scaledHeight == 640)
        #expect(transform.leftPadding == 80)
        #expect(transform.rightPadding == 80)
        #expect(transform.topPadding == 0)
        #expect(transform.bottomPadding == 0)
    }

    @Test("rounds a half pixel to the nearest even scaled dimension")
    func halfPixelUsesNearestEven() throws {
        // 640 * 3 / 256 = 7.5, so nearest-even rounding yields 8.
        let transform = try YuNetLetterboxTransform(
            sourceWidth: 256,
            sourceHeight: 3
        )

        #expect(transform.scaledWidth == 640)
        #expect(transform.scaledHeight == 8)
        #expect(transform.topPadding == 316)
        #expect(transform.bottomPadding == 316)
    }

    @Test("places the odd remainder on raster right and bottom")
    func oddRemainderUsesTrailingPadding() throws {
        // 640 * 2 / 3 = 426.666..., rounded to 427 leaves 213 vertical
        // padding pixels. The lower-left raster edge receives the extra one.
        let transform = try YuNetLetterboxTransform(
            sourceWidth: 3,
            sourceHeight: 2
        )

        #expect(transform.scaledWidth == 640)
        #expect(transform.scaledHeight == 427)
        #expect(transform.topPadding == 106)
        #expect(transform.bottomPadding == 107)
        #expect(transform.topPadding + transform.scaledHeight + transform.bottomPadding == 640)
    }

    @Test("places an odd horizontal remainder on raster right")
    func portraitOddRemainderUsesTrailingPadding() throws {
        // 640 * 2 / 3 = 426.666..., rounded to 427 leaves 213 horizontal
        // padding pixels. The raster right edge receives the extra one.
        let transform = try YuNetLetterboxTransform(
            sourceWidth: 2,
            sourceHeight: 3
        )

        #expect(transform.scaledWidth == 427)
        #expect(transform.scaledHeight == 640)
        #expect(transform.leftPadding == 106)
        #expect(transform.rightPadding == 107)
        #expect(transform.topPadding == 0)
        #expect(transform.bottomPadding == 0)
    }

    @Test("unmaps lower-left points from the padded 640 canvas")
    func unmapsLowerLeftPoints() throws {
        let transform = try YuNetLetterboxTransform(
            sourceWidth: 400,
            sourceHeight: 300
        )

        let point = try NormalizedPoint(x: 0.25, y: 0.75)
        let mapped = try transform.unmap(point: point)

        #expect(abs(mapped.x - 0.25) < 0.000_000_000_001)
        #expect(abs(mapped.y - (5.0 / 6.0)) < 0.000_000_000_001)

        let lowerEdge = try NormalizedPoint(x: 0.5, y: 80.0 / 640.0)
        let upperEdge = try NormalizedPoint(x: 0.5, y: 560.0 / 640.0)
        #expect(try transform.unmap(point: lowerEdge).y == 0)
        #expect(try transform.unmap(point: upperEdge).y == 1)
    }

    @Test("subtracts the odd bottom padding when unmapping lower-left geometry")
    func unmapsOddBottomPadding() throws {
        let transform = try YuNetLetterboxTransform(
            sourceWidth: 3,
            sourceHeight: 2
        )

        let lowerEdge = try NormalizedPoint(x: 0.5, y: 107.0 / 640.0)
        let upperEdge = try NormalizedPoint(x: 0.5, y: 534.0 / 640.0)
        #expect(try transform.unmap(point: lowerEdge).y == 0)
        #expect(try transform.unmap(point: upperEdge).y == 1)

        let fullContent = try NormalizedRect(
            x: 0,
            y: 107.0 / 640.0,
            width: 1,
            height: 427.0 / 640.0
        )
        #expect(
            try transform.unmap(rect: fullContent)
                == NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        )
    }

    @Test("unmaps lower-left rectangles while preserving geometry")
    func unmapsLowerLeftRectangles() throws {
        let transform = try YuNetLetterboxTransform(
            sourceWidth: 400,
            sourceHeight: 300
        )
        let canvasRect = try NormalizedRect(
            x: 0.25,
            y: 0.25,
            width: 0.5,
            height: 0.5
        )

        let mapped = try transform.unmap(rect: canvasRect)

        #expect(abs(mapped.x - 0.25) < 0.000_000_000_001)
        #expect(abs(mapped.y - (1.0 / 6.0)) < 0.000_000_000_001)
        #expect(abs(mapped.width - 0.5) < 0.000_000_000_001)
        #expect(abs(mapped.height - (2.0 / 3.0)) < 0.000_000_000_001)

        let fullContent = try NormalizedRect(
            x: 0,
            y: 80.0 / 640.0,
            width: 1,
            height: 480.0 / 640.0
        )
        #expect(
            try transform.unmap(rect: fullContent)
                == NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        )
    }

    @Test("rejects points or rectangles that enter or overlap padding")
    func rejectsPaddingContent() throws {
        let landscape = try YuNetLetterboxTransform(
            sourceWidth: 400,
            sourceHeight: 300
        )
        let portrait = try YuNetLetterboxTransform(
            sourceWidth: 300,
            sourceHeight: 400
        )

        #expect(throws: YuNetLetterboxTransformError.outOfContent) {
            try landscape.unmap(
                point: NormalizedPoint(x: 0.5, y: 0.1)
            )
        }
        #expect(throws: YuNetLetterboxTransformError.outOfContent) {
            try landscape.unmap(
                rect: NormalizedRect(
                    x: 0.25,
                    y: 0.1,
                    width: 0.5,
                    height: 0.1
                )
            )
        }
        #expect(throws: YuNetLetterboxTransformError.outOfContent) {
            try portrait.unmap(
                point: NormalizedPoint(x: 0.1, y: 0.5)
            )
        }
    }

    @Test("rejects invalid and unrepresentable source dimensions")
    func rejectsInvalidSourceDimensions() {
        #expect(throws: YuNetLetterboxTransformError.invalidSourceDimensions) {
            try YuNetLetterboxTransform(sourceWidth: 0, sourceHeight: 640)
        }
        #expect(throws: YuNetLetterboxTransformError.invalidSourceDimensions) {
            try YuNetLetterboxTransform(sourceWidth: 640, sourceHeight: -1)
        }
        #expect(throws: YuNetLetterboxTransformError.numericOverflow) {
            try YuNetLetterboxTransform(sourceWidth: Int.max, sourceHeight: 1)
        }
    }

    @Test("is Equatable and Sendable")
    func isEquatableAndSendable() throws {
        let first = try YuNetLetterboxTransform(sourceWidth: 400, sourceHeight: 300)
        let second = try YuNetLetterboxTransform(sourceWidth: 400, sourceHeight: 300)

        #expect(first == second)
        acceptsSendable(first)
        acceptsSendable(second)
    }

    @Test("redacts every typed error")
    func redactsErrors() {
        let errors: [YuNetLetterboxTransformError] = [
            .invalidSourceDimensions,
            .numericOverflow,
            .outOfContent
        ]
        let descriptions = errors.map { String(describing: $0) }
        let debugDescriptions = errors.map { String(reflecting: $0) }

        #expect(Set(descriptions).count == 1)
        #expect(Set(debugDescriptions).count == 1)
        for error in errors {
            #expect(Mirror(reflecting: error).children.isEmpty)
            #expect(!String(describing: error).contains("640"))
            #expect(!String(reflecting: error).contains("source"))
            acceptsSendable(error)
        }
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
