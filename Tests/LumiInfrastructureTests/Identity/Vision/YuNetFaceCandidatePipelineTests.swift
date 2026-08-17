import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("YuNet face candidate pipeline")
struct YuNetFaceCandidatePipelineTests {
    @Test("passes the preprocessed tensor to inference and returns empty output")
    func passesPreprocessedTensorForEmptyOutput() async throws {
        let frame = try makeFrame(width: 3, height: 2, bytesPerRow: 16)
        let expectedInput = try YuNetVImagePreprocessor().preprocess(frame: frame)
        let driver = RecordingPipelineDriver(outputs: makeRawTensors())
        let pipeline = try makePipeline(driver: driver)

        let faces = try await pipeline.detect(frame: frame)

        #expect(faces.isEmpty)
        #expect(await driver.callCount == 1)
        #expect(await driver.receivedValues == expectedInput.values)
    }

    @Test("maps a landscape face and preserves every explicit landmark role")
    func mapsLandscapeFaceAndLandmarkRoles() async throws {
        let frame = try makeFrame(width: 3, height: 2, bytesPerRow: 16)
        let canvasFace = makeCandidate(score: 0.96)
        let driver = RecordingPipelineDriver(
            outputs: makeRawTensors(candidates: [canvasFace])
        )
        let pipeline = try makePipeline(driver: driver)

        let faces = try await pipeline.detect(frame: frame)

        #expect(faces.count == 1)
        let transform = try YuNetLetterboxTransform(
            sourceWidth: frame.width,
            sourceHeight: frame.height
        )
        let expected = try mapCanvasFace(
            candidate: canvasFace,
            transform: transform
        )
        #expect(faces.first == expected)
        #expect(
            faces.first?.alignmentLandmarks?.openCVAlignCropOrder
                == expected.alignmentLandmarks?.openCVAlignCropOrder
        )
    }

    @Test("maps a portrait face with horizontal letterbox padding")
    func mapsPortraitFace() async throws {
        let frame = try makeFrame(width: 2, height: 3, bytesPerRow: 12)
        let canvasFace = makeCandidate(score: 0.95)
        let driver = RecordingPipelineDriver(
            outputs: makeRawTensors(candidates: [canvasFace])
        )
        let pipeline = try makePipeline(driver: driver)

        let faces = try await pipeline.detect(frame: frame)

        #expect(faces.count == 1)
        let transform = try YuNetLetterboxTransform(
            sourceWidth: frame.width,
            sourceHeight: frame.height
        )
        #expect(transform.leftPadding == 106)
        #expect(transform.rightPadding == 107)
        #expect(faces.first == (try mapCanvasFace(
            candidate: canvasFace,
            transform: transform
        )))
    }

    @Test("preserves postprocessor order and confidence")
    func preservesOrderAndConfidence() async throws {
        let frame = try makeFrame(width: 3, height: 2, bytesPerRow: 16)
        let first = makeCandidate(
            score: 0.97,
            row: 30,
            column: 30
        )
        let second = makeCandidate(
            score: 0.93,
            row: 30,
            column: 70
        )
        let driver = RecordingPipelineDriver(
            outputs: makeRawTensors(candidates: [first, second])
        )
        let pipeline = try makePipeline(driver: driver)

        let faces = try await pipeline.detect(frame: frame)

        #expect(faces.count == 2)
        #expect(faces.map(\.confidence) == [Double(first.score), Double(second.score)])
        #expect(faces[0] == (try mapCanvasFace(
            candidate: first,
            transform: YuNetLetterboxTransform(sourceWidth: 3, sourceHeight: 2)
        )))
        #expect(faces[1] == (try mapCanvasFace(
            candidate: second,
            transform: YuNetLetterboxTransform(sourceWidth: 3, sourceHeight: 2)
        )))
    }

    @Test("fails the whole frame when a bbox enters letterbox padding")
    func rejectsBoundingBoxPadding() async throws {
        let frame = try makeFrame(width: 3, height: 2, bytesPerRow: 16)
        let valid = makeCandidate(score: 0.96)
        let paddingBoundingBox = makeCandidate(
            score: 0.94,
            row: 5,
            column: 30,
            size: 40
        )
        let driver = RecordingPipelineDriver(
            outputs: makeRawTensors(candidates: [valid, paddingBoundingBox])
        )
        let pipeline = try makePipeline(driver: driver)

        await #expect(throws: YuNetFaceCandidatePipelineError.failed) {
            _ = try await pipeline.detect(frame: frame)
        }
        #expect(await driver.callCount == 1)
    }

    @Test("fails the whole frame when a landmark enters letterbox padding")
    func rejectsLandmarkPadding() async throws {
        let frame = try makeFrame(width: 3, height: 2, bytesPerRow: 16)
        let paddingLandmark = makeCandidate(
            score: 0.96,
            landmarks: [
                0.5, -23.75,
                2.5, 0.5,
                1.5, 1.5,
                0.5, 2.5,
                2.5, 2.5
            ]
        )
        let driver = RecordingPipelineDriver(
            outputs: makeRawTensors(candidates: [paddingLandmark])
        )
        let pipeline = try makePipeline(driver: driver)

        await #expect(throws: YuNetFaceCandidatePipelineError.failed) {
            _ = try await pipeline.detect(frame: frame)
        }
    }

    @Test("rejects malformed inference without leaking a payload")
    func redactsMalformedInference() async throws {
        let frame = try makeFrame(width: 3, height: 2, bytesPerRow: 16)
        var malformed = makeRawTensors()
        malformed[0] = YuNetRawTensor(
            name: malformed[0].name,
            shape: [1, 1, 1],
            values: [0]
        )
        let driver = RecordingPipelineDriver(outputs: malformed)
        let pipeline = try makePipeline(driver: driver)

        await #expect(throws: YuNetFaceCandidatePipelineError.failed) {
            _ = try await pipeline.detect(frame: frame)
        }
        let error = YuNetFaceCandidatePipelineError.failed
        #expect(String(describing: error) == "YuNet face candidate pipeline failed.")
        #expect(String(reflecting: error) == "YuNet face candidate pipeline failed.")
        #expect(Mirror(reflecting: error).children.isEmpty)
        #expect(!String(reflecting: error).contains("shape"))
    }

    @Test("does not return a partial result when a later face is invalid")
    func rejectsPartialResults() async throws {
        let frame = try makeFrame(width: 3, height: 2, bytesPerRow: 16)
        let valid = makeCandidate(score: 0.97)
        let paddingBoundingBox = makeCandidate(
            score: 0.93,
            row: 5,
            column: 70,
            size: 40
        )
        let driver = RecordingPipelineDriver(
            outputs: makeRawTensors(candidates: [valid, paddingBoundingBox])
        )
        let pipeline = try makePipeline(driver: driver)

        await #expect(throws: YuNetFaceCandidatePipelineError.failed) {
            _ = try await pipeline.detect(frame: frame)
        }
    }

    @Test("pre-cancellation does not call inference")
    func rejectsPreCancellationBeforeDriver() async throws {
        let driver = RecordingPipelineDriver(outputs: makeRawTensors())
        let pipeline = try makePipeline(driver: driver)
        let frame = try makeFrame(width: 3, height: 2, bytesPerRow: 16)
        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            _ = try await pipeline.detect(frame: frame)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await driver.callCount == 0)
    }

    @Test("preserves cancellation while inference is suspended")
    func preservesSuspendedCancellation() async throws {
        let driver = SuspendedPipelineDriver(outputs: makeRawTensors())
        let pipeline = try makePipeline(driver: driver)
        let frame = try makeFrame(width: 3, height: 2, bytesPerRow: 16)
        let task = Task {
            _ = try await pipeline.detect(frame: frame)
        }

        await driver.waitForStart()
        task.cancel()
        await driver.resume()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("keeps the pipeline and its failure Sendable and redacted")
    func valuesAreSendable() throws {
        let pipeline = try makePipeline(
            driver: RecordingPipelineDriver(outputs: makeRawTensors())
        )
        acceptsSendable(pipeline)
        acceptsSendable(YuNetFaceCandidatePipelineError.failed)
        let error = YuNetFaceCandidatePipelineError.failed
        #expect(String(describing: error) == "YuNet face candidate pipeline failed.")
        #expect(String(reflecting: error) == "YuNet face candidate pipeline failed.")
        #expect(Mirror(reflecting: error).children.isEmpty)
    }

    private struct Candidate {
        let score: Float
        let stride: Int
        let row: Int
        let column: Int
        let size: Int
        let landmarks: [Float]
    }

    private struct OutputFixture {
        let name: String
        let shape: [Int]
    }

    private static let outputFixtures = [
        OutputFixture(name: "cls_8", shape: [1, 6_400, 1]),
        OutputFixture(name: "cls_16", shape: [1, 1_600, 1]),
        OutputFixture(name: "cls_32", shape: [1, 400, 1]),
        OutputFixture(name: "obj_8", shape: [1, 6_400, 1]),
        OutputFixture(name: "obj_16", shape: [1, 1_600, 1]),
        OutputFixture(name: "obj_32", shape: [1, 400, 1]),
        OutputFixture(name: "bbox_8", shape: [1, 6_400, 4]),
        OutputFixture(name: "bbox_16", shape: [1, 1_600, 4]),
        OutputFixture(name: "bbox_32", shape: [1, 400, 4]),
        OutputFixture(name: "kps_8", shape: [1, 6_400, 10]),
        OutputFixture(name: "kps_16", shape: [1, 1_600, 10]),
        OutputFixture(name: "kps_32", shape: [1, 400, 10])
    ]

    private func makePipeline(
        driver: any YuNetCoreMLRawInferenceDriver
    ) throws -> YuNetFaceCandidatePipeline {
        let inference = YuNetCoreMLRawInference(driver: driver)
        let postprocessor = try YuNetPostprocessor()
        return YuNetFaceCandidatePipeline(
            inference: inference,
            postprocessor: postprocessor
        )
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

    private func makeCandidate(
        score: Float,
        stride: Int = 8,
        row: Int = 30,
        column: Int = 30,
        size: Int = 80,
        landmarks: [Float]? = nil
    ) -> Candidate {
        let offset = Float(size) / 8
        return Candidate(
            score: score,
            stride: stride,
            row: row,
            column: column,
            size: size,
            landmarks: landmarks ?? [
                0.5, 0.5,
                offset - 0.5, 0.5,
                offset / 2, offset / 2,
                0.5, offset - 0.5,
                offset - 0.5, offset - 0.5
            ]
        )
    }

    private func makeRawTensors(
        candidates: [Candidate] = []
    ) -> [YuNetRawTensor] {
        Self.outputFixtures.map { fixture in
            var values = Array(repeating: Float.zero, count: fixture.shape.reduce(1, *))
            let parts = fixture.name.split(separator: "_")
            let group = String(parts[0])
            let stride = Int(parts[1]) ?? 0
            let columns = 640 / stride

            for candidate in candidates
                where candidate.stride == stride
                    && candidate.row < columns
                    && candidate.column < columns {
                let cell = candidate.row * columns + candidate.column
                switch group {
                case "cls":
                    values[cell] = 1
                case "obj":
                    values[cell] = candidate.score * candidate.score
                case "bbox":
                    let offset = cell * 4
                    values[offset] = 0
                    values[offset + 1] = 0
                    values[offset + 2] = Foundation.log(Float(candidate.size) / Float(stride))
                    values[offset + 3] = Foundation.log(Float(candidate.size) / Float(stride))
                case "kps":
                    let offset = cell * 10
                    for index in 0..<10 {
                        values[offset + index] = candidate.landmarks[index]
                    }
                default:
                    break
                }
            }

            return YuNetRawTensor(
                name: fixture.name,
                shape: fixture.shape,
                values: values
            )
        }
    }

    private func mapCanvasFace(
        candidate: Candidate,
        transform: YuNetLetterboxTransform
    ) throws -> DetectedFace {
        let stride = Double(candidate.stride)
        let centerX = Double(candidate.column) * stride
        let centerY = Double(candidate.row) * stride
        let size = Double(candidate.size)
        let canvasRect = try NormalizedRect(
            x: (centerX - size / 2) / 640,
            y: 1 - (centerY + size / 2) / 640,
            width: size / 640,
            height: size / 640
        )
        let mappedRect = try transform.unmap(rect: canvasRect)

        var canvasLandmarkPoints: [SFaceAlignmentLandmarkRole: NormalizedPoint] = [:]
        for index in 0..<5 {
            let offset = index * 2
            let point = try normalizedCanvasPoint(
                x: (Double(candidate.column) + Double(candidate.landmarks[offset])) * stride / 640,
                y: (Double(candidate.row) + Double(candidate.landmarks[offset + 1])) * stride / 640
            )
            canvasLandmarkPoints[Self.role(at: index)] = point
        }
        var mappedPoints: [SFaceAlignmentLandmarkRole: NormalizedPoint] = [:]
        for role in SFaceAlignmentLandmarkRole.allCases {
            guard let canvasPoint = canvasLandmarkPoints[role] else {
                throw SFaceAlignmentLandmarksError.missing(role)
            }
            mappedPoints[role] = try transform.unmap(point: canvasPoint)
        }
        let landmarks = try SFaceAlignmentLandmarks(points: mappedPoints)
        return try DetectedFace(
            boundingBox: mappedRect,
            confidence: Double(candidate.score),
            alignmentLandmarks: landmarks
        )
    }

    private func normalizedCanvasPoint(x: Double, y: Double) throws -> NormalizedPoint {
        try NormalizedPoint(x: x, y: 1 - y)
    }

    private static func role(at index: Int) -> SFaceAlignmentLandmarkRole {
        switch index {
        case 0: return .subjectRightEye
        case 1: return .subjectLeftEye
        case 2: return .noseTip
        case 3: return .subjectRightMouthCorner
        default: return .subjectLeftMouthCorner
        }
    }

    private func acceptsSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}

private actor RecordingPipelineDriver: YuNetCoreMLRawInferenceDriver {
    private let outputs: [YuNetRawTensor]
    private(set) var receivedValues: [Float]?
    private(set) var callCount = 0

    init(outputs: [YuNetRawTensor]) {
        self.outputs = outputs
    }

    func predict(values: [Float]) async throws -> [YuNetRawTensor] {
        callCount += 1
        receivedValues = values
        return outputs
    }
}

private actor SuspendedPipelineDriver: YuNetCoreMLRawInferenceDriver {
    private let outputs: [YuNetRawTensor]
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resumeRequested = false
    private var resultContinuation: CheckedContinuation<[YuNetRawTensor], Error>?

    init(outputs: [YuNetRawTensor]) {
        self.outputs = outputs
    }

    func predict(values: [Float]) async throws -> [YuNetRawTensor] {
        _ = values
        started = true
        startWaiter?.resume()
        startWaiter = nil
        return try await withCheckedThrowingContinuation { continuation in
            if resumeRequested {
                continuation.resume(returning: outputs)
            } else {
                resultContinuation = continuation
            }
        }
    }

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    func resume() {
        resumeRequested = true
        resultContinuation?.resume(returning: outputs)
        resultContinuation = nil
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
