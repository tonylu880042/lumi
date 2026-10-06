import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("Face geometry observer", .serialized)
struct FaceGeometryObserverTests {
    @Test("maps one face to normalized and source-frame pixel geometry")
    func mapsSingleFaceGeometry() async throws {
        let values = [
            VisionFaceObservationValues(
                x: 0.125,
                y: 0.25,
                width: 0.5,
                height: 0.625,
                confidence: 0.8,
                yawRadians: 0.25,
                rollRadians: -0.5
            )
        ]
        let observer = FaceGeometryObserver(
            detector: VisionFaceDetector(provider: StaticVisionProvider(values: values))
        )

        let observation = try #require(
            try await observer.observe(frame: makeFrame(width: 640, height: 480))
        )
        let expectedBoundingBox = try NormalizedRect(
            x: 0.125,
            y: 0.25,
            width: 0.5,
            height: 0.625
        )

        #expect(observation.frameWidth == 640)
        #expect(observation.frameHeight == 480)
        #expect(observation.normalizedBoundingBox == expectedBoundingBox)
        #expect(observation.pixelBoundingBox.x == 80)
        #expect(observation.pixelBoundingBox.y == 120)
        #expect(observation.pixelBoundingBox.width == 320)
        #expect(observation.pixelBoundingBox.height == 300)
        #expect(observation.normalizedArea == 0.3125)
        #expect(observation.pixelArea == 96_000)
        #expect(observation.pose?.yawRadians == 0.25)
        #expect(observation.pose?.rollRadians == -0.5)
        acceptsSendable(observation)
    }

    @Test("no face fails closed without synthesizing geometry")
    func noFaceReturnsNil() async throws {
        let observer = FaceGeometryObserver(
            detector: VisionFaceDetector(provider: StaticVisionProvider(values: []))
        )

        let observation = try await observer.observe(frame: makeFrame())

        #expect(observation == nil)
    }

    @Test("multiple faces fail closed without selecting by size or confidence")
    func multipleFacesReturnNil() async throws {
        let observer = FaceGeometryObserver(
            detector: VisionFaceDetector(
                provider: StaticVisionProvider(values: [
                    VisionFaceObservationValues(
                        x: 0.1,
                        y: 0.1,
                        width: 0.2,
                        height: 0.2,
                        confidence: 0.2
                    ),
                    VisionFaceObservationValues(
                        x: 0.5,
                        y: 0.4,
                        width: 0.4,
                        height: 0.5,
                        confidence: 0.99
                    )
                ])
            )
        )

        let observation = try await observer.observe(frame: makeFrame())

        #expect(observation == nil)
    }

    @Test("preserves detector cancellation")
    func preservesCancellation() async {
        let observer = FaceGeometryObserver(
            detector: VisionFaceDetector(provider: CancellationVisionProvider())
        )

        await #expect(throws: CancellationError.self) {
            _ = try await observer.observe(frame: makeFrame())
        }
    }

    private func makeFrame(width: Int = 640, height: Int = 480) throws -> CameraFrame {
        try CameraFrame(
            bytes: Data(repeating: 0, count: width * height * 4),
            width: width,
            height: height,
            bytesPerRow: width * 4,
            orientation: .upright
        )
    }
}

private struct StaticVisionProvider: VisionFaceObservationProvider {
    let values: [VisionFaceObservationValues]

    func detect(frame: CameraFrame) async throws -> [VisionFaceObservationValues] {
        _ = frame
        return values
    }
}

private struct CancellationVisionProvider: VisionFaceObservationProvider {
    func detect(frame: CameraFrame) async throws -> [VisionFaceObservationValues] {
        _ = frame
        throw CancellationError()
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
