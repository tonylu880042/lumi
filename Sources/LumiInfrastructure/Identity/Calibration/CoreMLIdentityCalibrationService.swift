// Xcode 26 still imports Core ML without complete concurrency annotations.
// The shim is local: MLModel remains inside its existing actor-isolated
// inference adapters and never crosses the Application port.
#if DEBUG

@preconcurrency import CoreML
import Foundation
import LumiApplication
import LumiDomain

/// Internal camera boundary for the calibration service. The concrete source
/// owns the CameraCaptureAdapter stream and returns one owned frame per gate.
protocol IdentityCalibrationFrameSource: Sendable {
    func start() async throws
    func stop() async
    func nextFrame() async throws -> CameraFrame
}

/// Narrow adapter seam so the concrete one-shot frame gate can be tested
/// without a native camera. The production adapter's stream is
/// `.bufferingNewest(1)`.
protocol IdentityCalibrationCameraAdapter: Sendable {
    func start() async throws -> AsyncStream<CameraFrame>
    func stop() async
}

/// Internal frame-to-embedding boundary. Core ML and Vision remain behind it.
protocol IdentityCalibrationEmbeddingProducing: Sendable {
    func embedding(for frame: CameraFrame) async throws -> FaceEmbedding?
}

/// Internal typed store boundary used by the calibration service and fakes.
protocol IdentityCalibrationStore: Sendable {
    func save(
        memberID: MemberID,
        embedding: FaceEmbedding,
        createdAt: Date
    ) async throws

    func sFaceSamples() async throws -> [StoredFaceEmbeddingSample]

    func sFaceSamples(for memberID: MemberID) async throws -> [StoredFaceEmbeddingSample]

    func deleteRecords(for memberID: MemberID) async throws
}

/// Composes one manually gated camera frame with the existing Vision/YuNet/
/// SFace pipeline and the evidence-only matcher.
///
/// This actor is an Application-port implementation. It never returns a
/// CameraFrame, FaceEmbedding, SDK object, `UnknownReason`, or production
/// recognition decision to its caller.
public actor CoreMLIdentityCalibrationService: IdentityCalibrationPort {
    private let frameSource: any IdentityCalibrationFrameSource
    private let photoFrameSource: any IdentityCalibrationPhotoFrameSource
    private let embeddingPipeline: any IdentityCalibrationEmbeddingProducing
    private let store: any IdentityCalibrationStore
    private let matcher = BruteForceCosineFaceMatcher()
    private var captureInFlight = false

    /// Internal dependency injection keeps framework-free tests deterministic.
    init(
        frameSource: any IdentityCalibrationFrameSource,
        embeddingPipeline: any IdentityCalibrationEmbeddingProducing,
        store: any IdentityCalibrationStore,
        photoFrameSource: any IdentityCalibrationPhotoFrameSource =
            ImageIOIdentityCalibrationPhotoFrameDecoder()
    ) {
        self.frameSource = frameSource
        self.photoFrameSource = photoFrameSource
        self.embeddingPipeline = embeddingPipeline
        self.store = store
    }

    public func startCamera() async throws {
        do {
            try Task.checkCancellation()
            try await frameSource.start()
            try Task.checkCancellation()
        } catch let cancellation as CancellationError {
            await frameSource.stop()
            throw cancellation
        } catch {
            if Task.isCancelled {
                await frameSource.stop()
                throw CancellationError()
            }
            throw IdentityCalibrationError.failed
        }
    }

    public func stopCamera() async {
        await frameSource.stop()
    }

    public func captureEnrollmentSample(
        for temporaryMemberID: MemberID,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        do {
            try Task.checkCancellation()
            guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw IdentityCalibrationError.failed
            }

            guard let embedding = try await captureEmbedding() else {
                try Task.checkCancellation()
                return .noUsableFace
            }
            try Task.checkCancellation()

            try await store.save(
                memberID: temporaryMemberID,
                embedding: embedding,
                createdAt: createdAt
            )
            // Deliberately no post-save cancellation check. A non-cooperative
            // store may have committed; report the side-effect success rather
            // than making a retry look safe.
            return .stored
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw IdentityCalibrationError.failed
        }
    }

    public func captureEnrollmentPhoto(
        for temporaryMemberID: MemberID,
        from imageURL: URL,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        do {
            try Task.checkCancellation()
            guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw IdentityCalibrationError.failed
            }

            guard let embedding = try await captureEmbedding(from: imageURL) else {
                try Task.checkCancellation()
                return .noUsableFace
            }
            try Task.checkCancellation()

            try await store.save(
                memberID: temporaryMemberID,
                embedding: embedding,
                createdAt: createdAt
            )
            // A committed write wins a cancellation race, matching camera
            // enrollment semantics and avoiding a misleading retry signal.
            return .stored
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw IdentityCalibrationError.failed
        }
    }

    public func captureEnrollmentPhoto(
        for temporaryMemberID: MemberID,
        from photo: IdentityCalibrationPhoto,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        do {
            try Task.checkCancellation()
            guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw IdentityCalibrationError.failed
            }

            guard let embedding = try await captureEmbedding(from: photo) else {
                try Task.checkCancellation()
                return .noUsableFace
            }
            try Task.checkCancellation()

            try await store.save(
                memberID: temporaryMemberID,
                embedding: embedding,
                createdAt: createdAt
            )
            return .stored
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw IdentityCalibrationError.failed
        }
    }

    public func captureReturnVisit() async throws -> IdentityCalibrationReturnResult {
        do {
            try Task.checkCancellation()
            guard let embedding = try await captureEmbedding() else {
                try Task.checkCancellation()
                return .noUsableFace
            }
            try Task.checkCancellation()

            let samples = try await store.sFaceSamples()
            try Task.checkCancellation()
            let evidence = try matcher.evidence(
                for: embedding,
                against: samples
            )
            try Task.checkCancellation()

            return .measured(IdentityCalibrationEvidence(
                gallerySampleCount: samples.count,
                top1: Self.makeCandidate(from: evidence.bestCandidate),
                top2: Self.makeCandidate(from: evidence.secondCandidate)
            ))
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw IdentityCalibrationError.failed
        }
    }

    public func captureReturnVisitPhoto(
        from imageURL: URL
    ) async throws -> IdentityCalibrationReturnResult {
        do {
            try Task.checkCancellation()
            guard let embedding = try await captureEmbedding(from: imageURL) else {
                try Task.checkCancellation()
                return .noUsableFace
            }
            try Task.checkCancellation()

            let samples = try await store.sFaceSamples()
            try Task.checkCancellation()
            let evidence = try matcher.evidence(
                for: embedding,
                against: samples
            )
            try Task.checkCancellation()

            return .measured(IdentityCalibrationEvidence(
                gallerySampleCount: samples.count,
                top1: Self.makeCandidate(from: evidence.bestCandidate),
                top2: Self.makeCandidate(from: evidence.secondCandidate)
            ))
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw IdentityCalibrationError.failed
        }
    }

    public func captureReturnVisitPhoto(
        from photo: IdentityCalibrationPhoto
    ) async throws -> IdentityCalibrationReturnResult {
        do {
            try Task.checkCancellation()
            guard let embedding = try await captureEmbedding(from: photo) else {
                try Task.checkCancellation()
                return .noUsableFace
            }
            try Task.checkCancellation()

            let samples = try await store.sFaceSamples()
            try Task.checkCancellation()
            let evidence = try matcher.evidence(
                for: embedding,
                against: samples
            )
            try Task.checkCancellation()

            return .measured(IdentityCalibrationEvidence(
                gallerySampleCount: samples.count,
                top1: Self.makeCandidate(from: evidence.bestCandidate),
                top2: Self.makeCandidate(from: evidence.secondCandidate)
            ))
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw IdentityCalibrationError.failed
        }
    }

    public func sampleCount(for temporaryMemberID: MemberID) async throws -> Int {
        do {
            try Task.checkCancellation()
            let samples = try await store.sFaceSamples(for: temporaryMemberID)
            try Task.checkCancellation()
            return samples.count
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw IdentityCalibrationError.failed
        }
    }

    public func reset(for temporaryMemberID: MemberID) async throws {
        do {
            try Task.checkCancellation()
            try await store.deleteRecords(for: temporaryMemberID)
            // Deletion is an explicit side effect; do not turn a committed
            // reset into a retry signal with a post-delete cancellation check.
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw IdentityCalibrationError.failed
        }
    }

    private func captureEmbedding() async throws -> FaceEmbedding? {
        guard !captureInFlight else {
            throw IdentityCalibrationError.failed
        }
        captureInFlight = true
        defer { captureInFlight = false }

        let frame = try await frameSource.nextFrame()
        try Task.checkCancellation()
        return try await embeddingPipeline.embedding(for: frame)
    }

    private func captureEmbedding(from imageURL: URL) async throws -> FaceEmbedding? {
        guard !captureInFlight else {
            throw IdentityCalibrationError.failed
        }
        captureInFlight = true
        defer { captureInFlight = false }

        let frame = try await photoFrameSource.frame(from: imageURL)
        try Task.checkCancellation()
        return try await embeddingPipeline.embedding(for: frame)
    }

    private func captureEmbedding(
        from photo: IdentityCalibrationPhoto
    ) async throws -> FaceEmbedding? {
        guard !captureInFlight else {
            throw IdentityCalibrationError.failed
        }
        captureInFlight = true
        defer { captureInFlight = false }

        let frame = try await photoFrameSource.frame(from: photo)
        try Task.checkCancellation()
        return try await embeddingPipeline.embedding(for: frame)
    }

    private static func makeCandidate(
        from candidate: FaceMatchCandidate?
    ) -> IdentityCalibrationCandidate? {
        guard let candidate else { return nil }
        return IdentityCalibrationCandidate(
            memberID: candidate.memberID,
            cosineSimilarity: candidate.cosineSimilarity
        )
    }
}

/// Loads the two exact 40A compiled model resources and builds the concrete
/// calibration graph. The default Core ML configuration is intentional for
/// this DEBUG diagnostic; it is not a production compute-unit policy.
public enum CoreMLIdentityCalibrationFactory {
    public static func load(
        sFaceModelURL: URL,
        yuNetModelURL: URL,
        databaseURL: URL
    ) async throws -> CoreMLIdentityCalibrationService {
        do {
            try Task.checkCancellation()
            guard isCompiledModelURL(
                sFaceModelURL,
                expectedName: "SFace"
            ), isCompiledModelURL(
                yuNetModelURL,
                expectedName: "YuNet"
            ) else {
                throw IdentityCalibrationError.failed
            }

            let configuration = MLModelConfiguration()
            let sFaceModel = try await MLModel.load(
                contentsOf: sFaceModelURL,
                configuration: configuration
            )
            try Task.checkCancellation()
            let yuNetModel = try await MLModel.load(
                contentsOf: yuNetModelURL,
                configuration: configuration
            )
            try Task.checkCancellation()

            let sFaceInference = try SFaceCoreMLInference(model: sFaceModel)
            let yuNetInference = try YuNetCoreMLRawInference(model: yuNetModel)
            let postprocessor = try YuNetPostprocessor(
                configuration: .validationDefault
            )
            let yuNetCandidates = YuNetFaceCandidatePipeline(
                inference: yuNetInference,
                postprocessor: postprocessor
            )
            let embeddingPipeline = SFaceFrameEmbeddingPipeline(
                visionDetector: VisionFaceDetector(),
                yuNetDetector: yuNetCandidates,
                sFaceInference: sFaceInference
            )

#if canImport(SQLite3)
            let store = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
#if os(iOS)
            let permission = AVFoundationCameraPermissionClient()
#else
            let permission = AVFoundationCameraPermissionClient(
                statusReader: { .denied },
                accessRequester: { completion in completion(false) }
            )
#endif
            let cameraAdapter = CameraCaptureAdapter(
                permission: permission,
                backend: AVFoundationCameraCaptureBackend()
            )
            let frameSource = IdentityCalibrationCameraFrameSource(
                adapter: cameraAdapter
            )
            return CoreMLIdentityCalibrationService(
                frameSource: frameSource,
                embeddingPipeline: embeddingPipeline,
                store: store
            )
#else
            throw IdentityCalibrationError.failed
#endif
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw IdentityCalibrationError.failed
        }
    }

    static func isCompiledModelURL(
        _ url: URL,
        expectedName: String
    ) -> Bool {
        url.isFileURL
            && url.lastPathComponent == "\(expectedName).mlmodelc"
            && url.pathExtension == "mlmodelc"
            && FileManager.default.fileExists(atPath: url.path)
    }
}

#if canImport(SQLite3)
extension SQLiteFaceEmbeddingStore: IdentityCalibrationStore {}
#endif

extension SFaceFrameEmbeddingPipeline: IdentityCalibrationEmbeddingProducing {}
extension CameraCaptureAdapter: IdentityCalibrationCameraAdapter {}

#endif
