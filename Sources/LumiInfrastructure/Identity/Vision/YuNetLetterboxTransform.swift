import Foundation

/// Stable, payload-free failures for the YuNet canvas geometry boundary.
enum YuNetLetterboxTransformError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case invalidSourceDimensions
    case numericOverflow
    case outOfContent

    var description: String { "YuNet letterbox transform failed." }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}

/// Maps normalized lower-left coordinates on YuNet's 640×640 letterboxed
/// canvas back to the original frame's normalized lower-left coordinates.
///
/// This type describes geometry only. It deliberately does not resample
/// pixels or know anything about a camera, model tensor, or SDK image type.
struct YuNetLetterboxTransform: Equatable, Sendable {
    static let targetDimension = 640

    let scaledWidth: Int
    let scaledHeight: Int
    let leftPadding: Int
    let topPadding: Int
    let rightPadding: Int
    let bottomPadding: Int

    init(
        sourceWidth: Int,
        sourceHeight: Int
    ) throws(YuNetLetterboxTransformError) {
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw .invalidSourceDimensions
        }

        let sourceWidthValue = Double(sourceWidth)
        let sourceHeightValue = Double(sourceHeight)
        guard sourceWidthValue.isFinite, sourceHeightValue.isFinite,
              let exactWidth = Int(exactly: sourceWidthValue),
              exactWidth == sourceWidth,
              let exactHeight = Int(exactly: sourceHeightValue),
              exactHeight == sourceHeight else {
            throw .numericOverflow
        }

        let fittedWidth: Int
        let fittedHeight: Int
        if sourceWidth >= sourceHeight {
            fittedWidth = Self.targetDimension
            let unroundedHeight = Double(Self.targetDimension)
                * sourceHeightValue
                / sourceWidthValue
            fittedHeight = try Self.roundedDimension(unroundedHeight)
        } else {
            let unroundedWidth = Double(Self.targetDimension)
                * sourceWidthValue
                / sourceHeightValue
            fittedWidth = try Self.roundedDimension(unroundedWidth)
            fittedHeight = Self.targetDimension
        }

        let horizontalRemainder = Self.targetDimension - fittedWidth
        let verticalRemainder = Self.targetDimension - fittedHeight
        guard horizontalRemainder >= 0, verticalRemainder >= 0 else {
            throw .numericOverflow
        }

        self.scaledWidth = fittedWidth
        self.scaledHeight = fittedHeight
        // Raster placement uses floor on the top/left side. If the remainder
        // is odd, the extra pixel is on the raster right/bottom side.
        self.leftPadding = horizontalRemainder / 2
        self.rightPadding = horizontalRemainder - self.leftPadding
        self.topPadding = verticalRemainder / 2
        self.bottomPadding = verticalRemainder - self.topPadding
    }

    /// Maps one lower-left normalized point from the 640 canvas to the source.
    /// Points in padding are rejected rather than silently clamped.
    func unmap(
        point: NormalizedPoint
    ) throws(YuNetLetterboxTransformError) -> NormalizedPoint {
        let canvasX = point.x * Double(Self.targetDimension)
        let canvasY = point.y * Double(Self.targetDimension)
        guard canvasX.isFinite, canvasY.isFinite else {
            throw .numericOverflow
        }
        guard containsPoint(x: canvasX, y: canvasY) else {
            throw .outOfContent
        }

        return try makePoint(
            x: (canvasX - Double(leftPadding)) / Double(scaledWidth),
            y: (canvasY - Double(bottomPadding)) / Double(scaledHeight)
        )
    }

    /// Maps one lower-left normalized rectangle from the 640 canvas to the
    /// source. A rectangle must be fully contained in the image content.
    func unmap(
        rect: NormalizedRect
    ) throws(YuNetLetterboxTransformError) -> NormalizedRect {
        let canvasMinX = rect.x * Double(Self.targetDimension)
        let canvasMinY = rect.y * Double(Self.targetDimension)
        let canvasMaxX = rect.maxX * Double(Self.targetDimension)
        let canvasMaxY = rect.maxY * Double(Self.targetDimension)
        let canvasValues = [canvasMinX, canvasMinY, canvasMaxX, canvasMaxY]
        guard canvasValues.allSatisfy(\.isFinite) else {
            throw .numericOverflow
        }
        guard canvasMinX >= Double(leftPadding),
              canvasMaxX <= Double(Self.targetDimension - rightPadding),
              canvasMinY >= Double(bottomPadding),
              canvasMaxY <= Double(Self.targetDimension - topPadding) else {
            throw .outOfContent
        }

        let sourceX = (canvasMinX - Double(leftPadding)) / Double(scaledWidth)
        let sourceY = (canvasMinY - Double(bottomPadding)) / Double(scaledHeight)
        let sourceWidth = (canvasMaxX - canvasMinX) / Double(scaledWidth)
        let sourceHeight = (canvasMaxY - canvasMinY) / Double(scaledHeight)
        let sourceValues = [sourceX, sourceY, sourceWidth, sourceHeight]
        guard sourceValues.allSatisfy(\.isFinite) else {
            throw .numericOverflow
        }

        do {
            return try NormalizedRect(
                x: sourceX,
                y: sourceY,
                width: sourceWidth,
                height: sourceHeight
            )
        } catch {
            throw .numericOverflow
        }
    }

    private static func roundedDimension(
        _ value: Double
    ) throws(YuNetLetterboxTransformError) -> Int {
        guard value.isFinite, value > 0, value <= Double(targetDimension) else {
            throw .numericOverflow
        }

        let rounded = value.rounded(.toNearestOrEven)
        guard rounded.isFinite, rounded >= 1,
              rounded <= Double(targetDimension),
              let dimension = Int(exactly: rounded), dimension > 0 else {
            throw .numericOverflow
        }
        return dimension
    }

    private func containsPoint(x: Double, y: Double) -> Bool {
        x >= Double(leftPadding)
            && x <= Double(Self.targetDimension - rightPadding)
            && y >= Double(bottomPadding)
            && y <= Double(Self.targetDimension - topPadding)
    }

    private func makePoint(
        x: Double,
        y: Double
    ) throws(YuNetLetterboxTransformError) -> NormalizedPoint {
        guard x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y) else {
            throw .numericOverflow
        }

        do {
            return try NormalizedPoint(x: x, y: y)
        } catch {
            throw .numericOverflow
        }
    }
}
