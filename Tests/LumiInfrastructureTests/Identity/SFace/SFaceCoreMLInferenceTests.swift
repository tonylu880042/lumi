import CoreML
import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("SFace Core ML inference")
struct SFaceCoreMLInferenceTests {
    @Test("converts BGRA pixels to exact RGB NCHW and ignores alpha")
    func convertsBGRAtoRGBNCHWAndIgnoresAlpha() async throws {
        let first = try makeAlignedFace(alpha: { x, y in
            UInt8((x + y) & 0xFF)
        })
        let second = try makeAlignedFace(alpha: { x, y in
            UInt8(255 - ((x * 3 + y * 5) & 0xFF))
        })
        let firstDriver = RecordingDriver(outputs: Self.normalizedFixture)
        let secondDriver = RecordingDriver(outputs: Self.normalizedFixture)
        let firstInference = SFaceCoreMLInference(driver: firstDriver)
        let secondInference = SFaceCoreMLInference(driver: secondDriver)

        _ = try await firstInference.embedding(for: first)
        _ = try await secondInference.embedding(for: second)

        let firstValues = try #require(await firstDriver.receivedValues)
        let secondValues = try #require(await secondDriver.receivedValues)
        #expect(firstValues == secondValues)
        #expect(firstValues.count == Self.inputCount)
        #expect(firstValues == Self.expectedRGBValues)
    }

    @Test("normalizes exactly 128 outputs and preserves the SFace model version")
    func normalizesOutputAndUsesPinnedModelVersion() async throws {
        let driver = RecordingDriver(
            outputs: [3, 4] + Array(repeating: Float.zero, count: 126)
        )
        let inference = SFaceCoreMLInference(driver: driver)

        let embedding = try await inference.embedding(for: makeAlignedFace())

        #expect(embedding.modelVersion == SFaceCoreMLInference.modelVersion)
        #expect(embedding.modelVersion == "sface-opencv-zoo-4.10.0-fp32")
        #expect(embedding.components.count == 128)
        #expect(abs(embedding.components[0] - 0.6) < 0.000_001)
        #expect(abs(embedding.components[1] - 0.8) < 0.000_001)
        #expect(embedding.components.dropFirst(2).allSatisfy { $0 == 0 })
    }

    @Test("rejects malformed, non-finite, and zero output vectors")
    func rejectsMalformedOutputs() async throws {
        let malformed: [[Float]] = [
            Array(repeating: 1, count: 127),
            [Float.nan] + Array(repeating: 1, count: 127),
            Array(repeating: Float.zero, count: 128)
        ]

        for output in malformed {
            let inference = SFaceCoreMLInference(
                driver: RecordingDriver(outputs: output)
            )
            await #expect(throws: SFaceCoreMLInferenceError.failed) {
                _ = try await inference.embedding(for: makeAlignedFace())
            }
        }
    }

    @Test("redacts generic driver failures to one fixed error")
    func redactsDriverFailure() async throws {
        let inference = SFaceCoreMLInference(driver: FailingDriver())

        do {
            _ = try await inference.embedding(for: makeAlignedFace())
            Issue.record("expected driver failure")
        } catch let error as SFaceCoreMLInferenceError {
            #expect(error == .failed)
            #expect(String(describing: error) == "SFace Core ML inference failed.")
            #expect(String(reflecting: error) == "SFace Core ML inference failed.")
            #expect(Mirror(reflecting: error).children.isEmpty)
            #expect(!String(reflecting: error).contains(FailingDriver.marker))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("preserves direct driver cancellation")
    func preservesDirectCancellation() async throws {
        let inference = SFaceCoreMLInference(driver: CancellationDriver())

        await #expect(throws: CancellationError.self) {
            _ = try await inference.embedding(for: makeAlignedFace())
        }
    }

    @Test("pre-cancellation does not call the driver")
    func rejectsPreCancellationBeforeDriver() async throws {
        let driver = RecordingDriver(outputs: Self.normalizedFixture)
        let inference = SFaceCoreMLInference(driver: driver)
        let face = try makeAlignedFace()
        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            _ = try await inference.embedding(for: face)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await driver.callCount == 0)
    }

    @Test("preserves caller cancellation while the driver is suspended")
    func preservesCallerCancellation() async throws {
        let driver = SuspendedDriver()
        let inference = SFaceCoreMLInference(driver: driver)
        let face = try makeAlignedFace()
        let task = Task {
            _ = try await inference.embedding(for: face)
        }

        await driver.waitForStart()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("caller cancellation wins when the driver throws a generic failure")
    func cancellationWinsGenericDriverFailure() async throws {
        let driver = GenericFailureAfterCancellationDriver()
        let inference = SFaceCoreMLInference(driver: driver)
        let face = try makeAlignedFace()
        let task = Task {
            _ = try await inference.embedding(for: face)
        }

        await driver.waitForStart()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("copies logical values from a padded output stride")
    func copiesPaddedOutputStride() throws {
        let array = try makePaddedOutputArray()

        let values = try SFaceCoreMLModelDriver.copyOutput(
            named: "embedding",
            array: array
        )

        #expect(values == (0..<128).map(Float.init))
    }

    @Test("keeps the facade, error, and embedding Sendable")
    func valuesAreSendable() throws {
        let inference = SFaceCoreMLInference(
            driver: RecordingDriver(outputs: Self.normalizedFixture)
        )
        acceptsSendable(inference)
        acceptsSendable(SFaceCoreMLInferenceError.failed)
        acceptsSendable(
            try FaceEmbedding(
                modelVersion: SFaceCoreMLInference.modelVersion,
                components: [1]
            )
        )
    }

    private static let inputPlaneSize = 112 * 112
    private static let inputCount = inputPlaneSize * 3
    private static let normalizedFixture = [
        Float(1), Float(0)
    ] + Array(repeating: Float.zero, count: 126)
    private static let expectedRGBValues =
        Array(repeating: Float(33), count: inputPlaneSize)
        + Array(repeating: Float(22), count: inputPlaneSize)
        + Array(repeating: Float(11), count: inputPlaneSize)

    private func makeAlignedFace(
        alpha: (Int, Int) -> UInt8 = { _, _ in 255 }
    ) throws -> SFaceAlignedFace {
        let width = 112
        let height = 112
        var bytes = Array(repeating: UInt8.zero, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = 11
                bytes[offset + 1] = 22
                bytes[offset + 2] = 33
                bytes[offset + 3] = alpha(x, y)
            }
        }
        let frame = try CameraFrame(
            bytes: Data(bytes),
            width: width,
            height: height,
            bytesPerRow: width * 4,
            orientation: .upright
        )
        let landmarks = try canonicalLandmarks()
        return try SFaceAlignmentCropper().crop(
            frame: frame,
            landmarks: landmarks
        )
    }

    private func canonicalLandmarks() throws -> SFaceAlignmentLandmarks {
        let points = [
            (38.2946, 51.6963),
            (73.5318, 51.5014),
            (56.0252, 71.7366),
            (41.5493, 92.3655),
            (70.7299, 92.2041)
        ]
        let values = try zip(SFaceAlignmentLandmarkRole.allCases, points).map {
            role,
            point in
            (
                role,
                try NormalizedPoint(
                    x: point.0 / 112,
                    y: 1 - point.1 / 112
                )
            )
        }
        return try SFaceAlignmentLandmarks(
            points: Dictionary(uniqueKeysWithValues: values)
        )
    }

    private func makePaddedOutputArray() throws -> MLMultiArray {
        let physicalCount = 256
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: physicalCount)
        for index in 0..<physicalCount {
            buffer[index] = -999
        }
        for index in 0..<128 {
            buffer[index * 2] = Float(index)
        }

        return try MLMultiArray(
            dataPointer: UnsafeMutableRawPointer(buffer),
            shape: [1, 128],
            dataType: .float32,
            strides: [256, 2],
            deallocator: { pointer in
                pointer.assumingMemoryBound(to: Float.self).deallocate()
            }
        )
    }
}

private actor RecordingDriver: SFaceCoreMLInferenceDriver {
    private let outputs: [Float]
    private(set) var receivedValues: [Float]?
    private(set) var callCount = 0

    init(outputs: [Float]) {
        self.outputs = outputs
    }

    func predict(values: [Float]) async throws -> [Float] {
        callCount += 1
        receivedValues = values
        return outputs
    }
}

private actor FailingDriver: SFaceCoreMLInferenceDriver {
    static let marker = "sface-driver-secret-marker"

    func predict(values: [Float]) async throws -> [Float] {
        _ = values
        struct InjectedFailure: Error {
            let marker: String
        }
        throw InjectedFailure(marker: Self.marker)
    }
}

private actor CancellationDriver: SFaceCoreMLInferenceDriver {
    func predict(values: [Float]) async throws -> [Float] {
        _ = values
        throw CancellationError()
    }
}

private actor SuspendedDriver: SFaceCoreMLInferenceDriver {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false
    private var resultContinuation: CheckedContinuation<[Float], Error>?

    func predict(values: [Float]) async throws -> [Float] {
        _ = values
        started = true
        startWaiter?.resume()
        startWaiter = nil

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[Float], Error>) in
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

private actor GenericFailureAfterCancellationDriver: SFaceCoreMLInferenceDriver {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false
    private var resultContinuation: CheckedContinuation<[Float], Error>?

    func predict(values: [Float]) async throws -> [Float] {
        _ = values
        started = true
        startWaiter?.resume()
        startWaiter = nil

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[Float], Error>) in
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
