import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("Vision face detector", .serialized)
struct VisionFaceDetectorTests {
    @Test("returns zero observations without inventing a face")
    func returnsZeroObservations() async throws {
        let detector = VisionFaceDetector(provider: StaticVisionProvider(values: []))

        let faces = try await detector.detect(frame: makeFrame())

        #expect(faces.isEmpty)
    }

    @Test("maps one observation exactly in lower-left coordinates")
    func mapsOneObservation() async throws {
        let value = VisionFaceObservationValues(
            x: 0.125,
            y: 0.25,
            width: 0.5,
            height: 0.625,
            confidence: 0.75
        )
        let detector = VisionFaceDetector(
            provider: StaticVisionProvider(values: [value])
        )

        let faces = try await detector.detect(frame: makeFrame())

        #expect(faces.count == 1)
        let face = try #require(faces.first)
        let expectedBoundingBox = try NormalizedRect(
            x: value.x,
            y: value.y,
            width: value.width,
            height: value.height
        )
        #expect(face.boundingBox == expectedBoundingBox)
        #expect(face.boundingBox.coordinateOrigin == .lowerLeft)
        #expect(face.confidence == value.confidence)
        #expect(face.alignmentLandmarks == nil)
    }

    @Test("preserves multiple observation order and confidence boundaries")
    func preservesOrderAndBoundaries() async throws {
        let values = [
            VisionFaceObservationValues(
                x: 0.01,
                y: 0.02,
                width: 0.1,
                height: 0.2,
                confidence: 0
            ),
            VisionFaceObservationValues(
                x: 0.3,
                y: 0.4,
                width: 0.2,
                height: 0.3,
                confidence: 1
            )
        ]
        let detector = VisionFaceDetector(
            provider: StaticVisionProvider(values: values)
        )

        let faces = try await detector.detect(frame: makeFrame())

        #expect(faces.map(\.confidence) == [0, 1])
        #expect(faces.map(\.boundingBox.x) == values.map(\.x))
        #expect(faces.map(\.boundingBox.y) == values.map(\.y))
        #expect(faces.map(\.boundingBox.width) == values.map(\.width))
        #expect(faces.map(\.boundingBox.height) == values.map(\.height))
        #expect(faces.allSatisfy { $0.alignmentLandmarks == nil })
    }

    @Test("rejects malformed observations as one fixed failure without partial output")
    func rejectsMalformedObservations() async throws {
        let valid = VisionFaceObservationValues(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.4,
            confidence: 0.5
        )
        let malformedValues = [
            VisionFaceObservationValues(
                x: .nan,
                y: 0.2,
                width: 0.3,
                height: 0.4,
                confidence: 0.5
            ),
            VisionFaceObservationValues(
                x: -0.1,
                y: 0.2,
                width: 0.3,
                height: 0.4,
                confidence: 0.5
            ),
            VisionFaceObservationValues(
                x: 0.8,
                y: 0.2,
                width: 0.3,
                height: 0.4,
                confidence: 0.5
            ),
            VisionFaceObservationValues(
                x: 0.1,
                y: 0.2,
                width: 0,
                height: 0.4,
                confidence: 0.5
            ),
            VisionFaceObservationValues(
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.4,
                confidence: .nan
            ),
            VisionFaceObservationValues(
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.4,
                confidence: -0.1
            ),
            VisionFaceObservationValues(
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.4,
                confidence: 1.1
            )
        ]

        for malformed in malformedValues {
            let detector = VisionFaceDetector(
                provider: StaticVisionProvider(values: [valid, malformed])
            )

            await #expect(throws: VisionFaceDetectorError.failed) {
                _ = try await detector.detect(frame: makeFrame())
            }
        }
    }

    @Test("redacts provider failures to one fixed error")
    func redactsProviderFailure() async throws {
        let detector = VisionFaceDetector(provider: FailingVisionProvider())
        let marker = FailingVisionProvider.marker

        do {
            _ = try await detector.detect(frame: makeFrame())
            Issue.record("expected provider failure")
        } catch let error as VisionFaceDetectorError {
            #expect(error == .failed)
            #expect(!String(describing: error).contains(marker))
            #expect(!String(reflecting: error).contains(marker))
            #expect(Mirror(reflecting: error).children.isEmpty)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("preserves direct provider cancellation")
    func preservesDirectProviderCancellation() async throws {
        let detector = VisionFaceDetector(
            provider: CancellationVisionProvider()
        )

        await #expect(throws: CancellationError.self) {
            _ = try await detector.detect(frame: makeFrame())
        }
    }

    @Test("preserves caller cancellation while provider is suspended")
    func preservesCallerCancellation() async throws {
        let provider = SuspendedVisionProvider()
        let detector = VisionFaceDetector(provider: provider)
        let task = Task {
            try await detector.detect(frame: makeFrame())
        }

        await provider.waitForStart()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("caller cancellation wins when provider throws a generic failure")
    func callerCancellationWinsGenericProviderFailure() async throws {
        let provider = GenericFailureAfterCancellationProvider()
        let detector = VisionFaceDetector(provider: provider)
        let task = Task {
            try await detector.detect(frame: makeFrame())
        }

        await provider.waitForStart()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("detector and raw observations are Sendable values")
    func detectorIsSendable() {
        let value = VisionFaceObservationValues(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.4,
            confidence: 0.5
        )
        let detector = VisionFaceDetector(
            provider: StaticVisionProvider(values: [value])
        )

        acceptsSendable(value)
        acceptsSendable(detector)
    }

    private func makeFrame() throws -> CameraFrame {
        try CameraFrame(
            bytes: Data(repeating: 0, count: 8),
            width: 1,
            height: 2,
            bytesPerRow: 4,
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

private struct FailingVisionProvider: VisionFaceObservationProvider {
    static let marker = "vision-provider-secret-marker"

    func detect(frame: CameraFrame) async throws -> [VisionFaceObservationValues] {
        _ = frame
        struct InjectedFailure: Error {
            let marker: String
        }
        throw InjectedFailure(marker: Self.marker)
    }
}

private struct CancellationVisionProvider: VisionFaceObservationProvider {
    func detect(frame: CameraFrame) async throws -> [VisionFaceObservationValues] {
        _ = frame
        throw CancellationError()
    }
}

private actor SuspendedVisionProvider: VisionFaceObservationProvider {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false
    private var resultContinuation: CheckedContinuation<
        [VisionFaceObservationValues],
        Error
    >?

    func detect(frame: CameraFrame) async throws -> [VisionFaceObservationValues] {
        _ = frame
        started = true
        startWaiter?.resume()
        startWaiter = nil

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[VisionFaceObservationValues], Error>) in
                if cancellationRequested {
                    continuation.resume(throwing: CancellationError())
                } else {
                    resultContinuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWithCancellationError() }
        })
    }

    func waitForStart() async {
        if started { return }

        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    private func cancelWithCancellationError() {
        cancellationRequested = true
        resultContinuation?.resume(throwing: CancellationError())
        resultContinuation = nil
    }
}

private actor GenericFailureAfterCancellationProvider: VisionFaceObservationProvider {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false
    private var resultContinuation: CheckedContinuation<
        [VisionFaceObservationValues],
        Error
    >?

    func detect(frame: CameraFrame) async throws -> [VisionFaceObservationValues] {
        _ = frame
        started = true
        startWaiter?.resume()
        startWaiter = nil

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[VisionFaceObservationValues], Error>) in
                if cancellationRequested {
                    continuation.resume(throwing: GenericFailure())
                } else {
                    resultContinuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWithGenericFailure() }
        })
    }

    func waitForStart() async {
        if started { return }

        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    private func cancelWithGenericFailure() {
        cancellationRequested = true
        resultContinuation?.resume(throwing: GenericFailure())
        resultContinuation = nil
    }

    private struct GenericFailure: Error {}
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
