import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("SFace frame embedding pipeline")
struct SFaceFrameEmbeddingPipelineTests {
    @Test("zero or multiple Vision faces skip YuNet and return nil")
    func visionTargetMustBeUnique() async throws {
        let frame = try makeFrame()
        let soleFace = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.7,
            landmarks: try makeLandmarks(seed: 0.02)
        )
        let cases = [
            [],
            [soleFace, soleFace]
        ]

        for visionFaces in cases {
            let vision = RecordingVisionDetector(.values(visionFaces))
            let yuNet = RecordingYuNetDetector(.values([soleFace]))
            let embedding = RecordingEmbeddingInferrer(.success(try makeEmbedding()))
            let pipeline = makePipeline(
                vision: vision,
                yuNet: yuNet,
                embedding: embedding
            )

            let result = try await pipeline.embedding(for: frame)

            #expect(result == nil)
            #expect(await vision.callCount == 1)
            #expect(await yuNet.callCount == 0)
            #expect(await embedding.callCount == 0)
        }
    }

    @Test("zero, multiple, or mismatched YuNet candidates do not crop or embed")
    func yuNetCandidateMustBeUniqueAndPairable() async throws {
        let frame = try makeFrame()
        let vision = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.7,
            landmarks: try makeLandmarks(seed: 0.02)
        )
        let candidate = try makeFace(
            rect: try makeRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            confidence: 0.9,
            landmarks: try makeLandmarks(seed: 0.01)
        )
        let mismatch = try makeFace(
            rect: try makeRect(x: 0.8, y: 0.05, width: 0.1, height: 0.1),
            confidence: 0.99,
            landmarks: try makeLandmarks(seed: 0.01)
        )
        let cases = [
            [],
            [candidate, candidate],
            [mismatch]
        ]

        for candidates in cases {
            let visionDetector = RecordingVisionDetector(.values([vision]))
            let yuNetDetector = RecordingYuNetDetector(.values(candidates))
            let embedding = RecordingEmbeddingInferrer(.success(try makeEmbedding()))
            let pipeline = makePipeline(
                vision: visionDetector,
                yuNet: yuNetDetector,
                embedding: embedding
            )

            let result = try await pipeline.embedding(for: frame)

            #expect(result == nil)
            #expect(await yuNetDetector.callCount == 1)
            #expect(await embedding.callCount == 0)
        }
    }

    @Test("paired path crops YuNet landmarks and returns the embedding")
    func pairedPathUsesYuNetLandmarksAndReturnsExactEmbedding() async throws {
        let frame = try makeFrame()
        let visionLandmarks = try makeLandmarks(seed: 0.08)
        let yuNetLandmarks = try makeLandmarks(seed: 0.01)
        let vision = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.62,
            landmarks: visionLandmarks
        )
        let candidate = try makeFace(
            rect: try makeRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            confidence: 0.98,
            landmarks: yuNetLandmarks
        )
        let expectedAlignedFace = try SFaceAlignmentCropper().crop(
            frame: frame,
            landmarks: yuNetLandmarks
        )
        let expectedEmbedding = try makeEmbedding()
        let visionDetector = RecordingVisionDetector(.values([vision]))
        let yuNetDetector = RecordingYuNetDetector(.values([candidate]))
        let embedding = RecordingEmbeddingInferrer(.success(expectedEmbedding))
        let pipeline = makePipeline(
            vision: visionDetector,
            yuNet: yuNetDetector,
            embedding: embedding
        )

        let result = try await pipeline.embedding(for: frame)

        #expect(result == expectedEmbedding)
        #expect(await visionDetector.lastFrame == frame)
        #expect(await yuNetDetector.lastFrame == frame)
        #expect(await embedding.callCount == 1)
        #expect(await embedding.receivedFace == expectedAlignedFace)
    }

    @Test("Vision failure is redacted and prevents later stages")
    func redactsVisionFailure() async throws {
        let diagnostics = SFacePipelineDiagnosticRecorder()
        let vision = RecordingVisionDetector(.failure)
        let yuNet = RecordingYuNetDetector(.values([]))
        let embedding = RecordingEmbeddingInferrer(.success(try makeEmbedding()))
        let pipeline = makePipeline(
            vision: vision,
            yuNet: yuNet,
            embedding: embedding,
            diagnosticSink: diagnostics.record
        )

        await #expect(throws: SFaceFrameEmbeddingPipelineError.failed) {
            _ = try await pipeline.embedding(for: makeFrame())
        }
        #expect(await yuNet.callCount == 0)
        #expect(await embedding.callCount == 0)
        #expect(diagnostics.events == [.framePipelineFailedVision])
    }

    @Test("YuNet failure is redacted and prevents crop and inference")
    func redactsYuNetFailure() async throws {
        let diagnostics = SFacePipelineDiagnosticRecorder()
        let face = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.7,
            landmarks: try makeLandmarks(seed: 0.02)
        )
        let vision = RecordingVisionDetector(.values([face]))
        let yuNet = RecordingYuNetDetector(.failure)
        let embedding = RecordingEmbeddingInferrer(.success(try makeEmbedding()))
        let pipeline = makePipeline(
            vision: vision,
            yuNet: yuNet,
            embedding: embedding,
            diagnosticSink: diagnostics.record
        )

        await #expect(throws: SFaceFrameEmbeddingPipelineError.failed) {
            _ = try await pipeline.embedding(for: makeFrame())
        }
        #expect(await yuNet.callCount == 1)
        #expect(await embedding.callCount == 0)
        #expect(diagnostics.events == [.framePipelineFailedYuNet])
    }

    @Test("degenerate paired landmarks fail closed before inference")
    func redactsCropFailure() async throws {
        let diagnostics = SFacePipelineDiagnosticRecorder()
        let vision = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.7,
            landmarks: try makeLandmarks(seed: 0.02)
        )
        let degenerate = try makeFace(
            rect: try makeRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            confidence: 0.9,
            landmarks: try makeDegenerateLandmarks()
        )
        let embedding = RecordingEmbeddingInferrer(.success(try makeEmbedding()))
        let pipeline = makePipeline(
            vision: RecordingVisionDetector(.values([vision])),
            yuNet: RecordingYuNetDetector(.values([degenerate])),
            embedding: embedding,
            diagnosticSink: diagnostics.record
        )

        await #expect(throws: SFaceFrameEmbeddingPipelineError.failed) {
            _ = try await pipeline.embedding(for: makeFrame())
        }
        #expect(await embedding.callCount == 0)
        #expect(diagnostics.events == [.framePipelineFailedAlignment])
    }

    @Test("SFace inference failure is redacted after the crop")
    func redactsEmbeddingFailure() async throws {
        let diagnostics = SFacePipelineDiagnosticRecorder()
        let (vision, candidate) = try makePair()
        let embedding = RecordingEmbeddingInferrer(.failure)
        let pipeline = makePipeline(
            vision: RecordingVisionDetector(.values([vision])),
            yuNet: RecordingYuNetDetector(.values([candidate])),
            embedding: embedding,
            diagnosticSink: diagnostics.record
        )

        await #expect(throws: SFaceFrameEmbeddingPipelineError.failed) {
            _ = try await pipeline.embedding(for: makeFrame())
        }
        #expect(await embedding.callCount == 1)
        #expect(await embedding.receivedFace != nil)
        #expect(diagnostics.events == [.framePipelineFailedSFace])
    }

    @Test("pipeline redacts errors without exposing underlying payload")
    func errorIsFixedAndRedacted() async throws {
        let pipeline = makePipeline(
            vision: RecordingVisionDetector(.failure),
            yuNet: RecordingYuNetDetector(.values([])),
            embedding: RecordingEmbeddingInferrer(.failure)
        )

        do {
            _ = try await pipeline.embedding(for: makeFrame())
            Issue.record("expected pipeline failure")
        } catch let error as SFaceFrameEmbeddingPipelineError {
            #expect(error == .failed)
            #expect(String(describing: error) == "SFace frame embedding pipeline failed.")
            #expect(String(reflecting: error) == "SFace frame embedding pipeline failed.")
            #expect(Mirror(reflecting: error).children.isEmpty)
            #expect(!String(reflecting: error).contains("underlying"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("pre-cancellation skips Vision")
    func preCancellationSkipsVision() async throws {
        let vision = RecordingVisionDetector(.values([]))
        let pipeline = makePipeline(
            vision: vision,
            yuNet: RecordingYuNetDetector(.values([])),
            embedding: RecordingEmbeddingInferrer(.success(try makeEmbedding()))
        )
        let frame = try makeFrame()
        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            _ = try await pipeline.embedding(for: frame)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await vision.callCount == 0)
    }

    @Test("cancellation while Vision is suspended is preserved")
    func suspendedVisionCancellationIsPreserved() async throws {
        let vision = SuspendedVisionDetector(outcome: .cancellation)
        let yuNet = RecordingYuNetDetector(.values([]))
        let embedding = RecordingEmbeddingInferrer(.success(try makeEmbedding()))
        let pipeline = makePipeline(
            vision: vision,
            yuNet: yuNet,
            embedding: embedding
        )
        let task = Task {
            _ = try await pipeline.embedding(for: makeFrame())
        }

        await vision.waitForStart()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await yuNet.callCount == 0)
        #expect(await embedding.callCount == 0)
    }

    @Test("cancellation wins when a Vision stage throws a generic error")
    func cancellationWinsGenericFailure() async throws {
        let vision = SuspendedVisionDetector(outcome: .genericFailure)
        let pipeline = makePipeline(
            vision: vision,
            yuNet: RecordingYuNetDetector(.values([])),
            embedding: RecordingEmbeddingInferrer(.success(try makeEmbedding()))
        )
        let task = Task {
            _ = try await pipeline.embedding(for: makeFrame())
        }

        await vision.waitForStart()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("pipeline and error are Sendable values")
    func valuesAreSendable() throws {
        let pipeline = makePipeline(
            vision: RecordingVisionDetector(.values([])),
            yuNet: RecordingYuNetDetector(.values([])),
            embedding: RecordingEmbeddingInferrer(.success(try makeEmbedding()))
        )

        acceptsSendable(pipeline)
        acceptsSendable(SFaceFrameEmbeddingPipelineError.failed)
    }

    private func makePipeline(
        vision: any VisionFaceDetecting,
        yuNet: any YuNetFaceCandidateDetecting,
        embedding: any SFaceEmbeddingInferring,
        diagnosticSink: @escaping IdentityDiagnosticSink =
            IdentityDiagnostics.record
    ) -> SFaceFrameEmbeddingPipeline {
        SFaceFrameEmbeddingPipeline(
            visionDetector: vision,
            yuNetDetector: yuNet,
            sFaceInference: embedding,
            diagnosticSink: diagnosticSink
        )
    }

    private func makePair() throws -> (DetectedFace, DetectedFace) {
        let vision = try makeFace(
            rect: try makeRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.62,
            landmarks: try makeLandmarks(seed: 0.08)
        )
        let candidate = try makeFace(
            rect: try makeRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            confidence: 0.98,
            landmarks: try makeLandmarks(seed: 0.01)
        )
        return (vision, candidate)
    }

    private func makeFrame() throws -> CameraFrame {
        let width = 160
        let height = 120
        let bytesPerRow = width * 4 + 8
        var bytes = Array(repeating: UInt8.zero, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                bytes[offset] = UInt8((x + y) & 0xFF)
                bytes[offset + 1] = UInt8(x & 0xFF)
                bytes[offset + 2] = UInt8(y & 0xFF)
                bytes[offset + 3] = 255
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

    private func makeFace(
        rect: NormalizedRect,
        confidence: Double,
        landmarks: SFaceAlignmentLandmarks?
    ) throws -> DetectedFace {
        try DetectedFace(
            boundingBox: rect,
            confidence: confidence,
            alignmentLandmarks: landmarks
        )
    }

    private func makeRect(
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) throws -> NormalizedRect {
        try NormalizedRect(x: x, y: y, width: width, height: height)
    }

    private func makeLandmarks(seed: Double) throws -> SFaceAlignmentLandmarks {
        let coordinates: [
            (SFaceAlignmentLandmarkRole, Double, Double)
        ] = [
            (.subjectRightEye, 0.34 + seed, 0.68 + seed),
            (.subjectLeftEye, 0.66 + seed, 0.68 + seed),
            (.noseTip, 0.50 + seed, 0.52 + seed),
            (.subjectRightMouthCorner, 0.38 + seed, 0.34 + seed),
            (.subjectLeftMouthCorner, 0.62 + seed, 0.34 + seed)
        ]
        var points: [SFaceAlignmentLandmarkRole: NormalizedPoint] = [:]
        for (role, x, y) in coordinates {
            points[role] = try NormalizedPoint(x: x, y: y)
        }
        return try SFaceAlignmentLandmarks(points: points)
    }

    private func makeDegenerateLandmarks() throws -> SFaceAlignmentLandmarks {
        let point = try NormalizedPoint(x: 0.5, y: 0.5)
        return try SFaceAlignmentLandmarks(
            points: Dictionary(
                uniqueKeysWithValues: SFaceAlignmentLandmarkRole.allCases.map {
                    ($0, point)
                }
            )
        )
    }

    private func makeEmbedding() throws -> FaceEmbedding {
        try FaceEmbedding(
            modelVersion: SFaceCoreMLInference.modelVersion,
            components: [1] + Array(repeating: Float.zero, count: 127)
        )
    }
}

private final class SFacePipelineDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [IdentityDiagnosticEvent] = []

    var events: [IdentityDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ event: IdentityDiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }
}

private enum FakeStageError: Error, Sendable {
    case failed
}

private enum DetectorOutcome: Sendable {
    case values([DetectedFace])
    case failure
}

private enum EmbeddingOutcome: Sendable {
    case success(FaceEmbedding)
    case failure
}

private actor RecordingVisionDetector: VisionFaceDetecting {
    private let outcome: DetectorOutcome
    private(set) var callCount = 0
    private(set) var lastFrame: CameraFrame?

    init(_ outcome: DetectorOutcome) {
        self.outcome = outcome
    }

    func detect(frame: CameraFrame) async throws -> [DetectedFace] {
        callCount += 1
        lastFrame = frame
        switch outcome {
        case .values(let faces):
            return faces
        case .failure:
            throw FakeStageError.failed
        }
    }
}

private actor RecordingYuNetDetector: YuNetFaceCandidateDetecting {
    private let outcome: DetectorOutcome
    private(set) var callCount = 0
    private(set) var lastFrame: CameraFrame?

    init(_ outcome: DetectorOutcome) {
        self.outcome = outcome
    }

    func detect(frame: CameraFrame) async throws -> [DetectedFace] {
        callCount += 1
        lastFrame = frame
        switch outcome {
        case .values(let faces):
            return faces
        case .failure:
            throw FakeStageError.failed
        }
    }
}

private actor RecordingEmbeddingInferrer: SFaceEmbeddingInferring {
    private let outcome: EmbeddingOutcome
    private(set) var callCount = 0
    private(set) var receivedFace: SFaceAlignedFace?

    init(_ outcome: EmbeddingOutcome) {
        self.outcome = outcome
    }

    func embedding(for face: SFaceAlignedFace) async throws -> FaceEmbedding {
        callCount += 1
        receivedFace = face
        switch outcome {
        case .success(let embedding):
            return embedding
        case .failure:
            throw FakeStageError.failed
        }
    }
}

private enum SuspendedVisionOutcome: Sendable {
    case cancellation
    case genericFailure
}

private actor SuspendedVisionDetector: VisionFaceDetecting {
    private let outcome: SuspendedVisionOutcome
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false
    private var resultContinuation: CheckedContinuation<[DetectedFace], Error>?
    private(set) var callCount = 0

    init(outcome: SuspendedVisionOutcome) {
        self.outcome = outcome
    }

    func detect(frame: CameraFrame) async throws -> [DetectedFace] {
        _ = frame
        callCount += 1
        started = true
        startWaiter?.resume()
        startWaiter = nil

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[DetectedFace], Error>) in
                if cancellationRequested {
                    resumeAfterCancellation(continuation)
                } else {
                    resultContinuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWithConfiguredFailure() }
        })
    }

    func waitForStart() async {
        if started { return }

        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    private func cancelWithConfiguredFailure() {
        cancellationRequested = true
        if let resultContinuation {
            resumeAfterCancellation(resultContinuation)
            self.resultContinuation = nil
        }
    }

    private func resumeAfterCancellation(
        _ continuation: CheckedContinuation<[DetectedFace], Error>
    ) {
        switch outcome {
        case .cancellation:
            continuation.resume(throwing: CancellationError())
        case .genericFailure:
            continuation.resume(throwing: FakeStageError.failed)
        }
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
