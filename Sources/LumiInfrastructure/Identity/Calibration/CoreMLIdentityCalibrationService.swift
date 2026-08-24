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
    func previewFrames() async -> AsyncStream<CameraFrame>
}

extension IdentityCalibrationFrameSource {
    /// Compatibility default for existing DEBUG-only frame-source fakes. The
    /// stream is finished immediately and never starts a camera or worker.
    func previewFrames() async -> AsyncStream<CameraFrame> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
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

/// Atomic persistence boundary for a completed conversational enrollment.
/// Pending embeddings remain owned by the service and never reach this store
/// until a valid spoken address is available.
protocol VisitorEnrollmentStore: Sendable {
    func commitVisitorEnrollment(
        memberID: MemberID,
        address: VoiceMemberAddress,
        consentedAt: Date,
        completedAt: Date,
        embeddings: [FaceEmbedding]
    ) async throws

    func address(for memberID: MemberID) async throws -> VoiceMemberAddress?
}

/// Composes one manually gated camera frame with the existing Vision/YuNet/
/// SFace pipeline and the evidence-only matcher.
///
/// This actor is an Application-port implementation. It never returns a
/// CameraFrame, FaceEmbedding, SDK object, `UnknownReason`, or production
/// recognition decision to its caller.
public actor CoreMLIdentityCalibrationService:
    IdentityCalibrationPort,
    VisitorEnrollmentPort,
    VoiceMemberAddressRepository
{
    private let frameSource: any IdentityCalibrationFrameSource
    private let photoFrameSource: any IdentityCalibrationPhotoFrameSource
    private let embeddingPipeline: any IdentityCalibrationEmbeddingProducing
    private let store: any IdentityCalibrationStore
    private let visitorEnrollmentStore: (any VisitorEnrollmentStore)?
    private let matcher = BruteForceCosineFaceMatcher()
    private let captureGate = IdentityCalibrationCaptureGate()
    private let cameraLeaseCoordinator: IdentityCalibrationCameraLeaseCoordinator
    private var manuallyHeldCameraLeases: [IdentityCalibrationCameraLeaseCoordinator.Lease] = []
    private var enrollmentGeneration: UInt64 = 0
    private var enrollmentInProgress = false
    private var pendingEnrollment: PendingVisitorEnrollment?

    /// Internal dependency injection keeps framework-free tests deterministic.
    init(
        frameSource: any IdentityCalibrationFrameSource,
        embeddingPipeline: any IdentityCalibrationEmbeddingProducing,
        store: any IdentityCalibrationStore,
        visitorEnrollmentStore: (any VisitorEnrollmentStore)? = nil,
        photoFrameSource: any IdentityCalibrationPhotoFrameSource =
            ImageIOIdentityCalibrationPhotoFrameDecoder()
    ) {
        self.frameSource = frameSource
        self.photoFrameSource = photoFrameSource
        self.embeddingPipeline = embeddingPipeline
        self.store = store
        self.visitorEnrollmentStore = visitorEnrollmentStore
        self.cameraLeaseCoordinator = IdentityCalibrationCameraLeaseCoordinator(
            frameSource: frameSource
        )
    }

    public func begin(
        consentedAt: Date
    ) async throws -> VisitorEnrollmentBeginResult {
        guard
            pendingEnrollment == nil,
            !enrollmentInProgress,
            consentedAt.timeIntervalSinceReferenceDate.isFinite,
            visitorEnrollmentStore != nil
        else {
            throw IdentityCalibrationError.failed
        }

        enrollmentInProgress = true
        defer { enrollmentInProgress = false }
        enrollmentGeneration &+= 1
        let generation = enrollmentGeneration

        do {
            let result = try await withCameraLease {
                try await self.withEnrollmentCaptureSlot {
                    try Task.checkCancellation()

                    var embeddings: [FaceEmbedding] = []
                    embeddings.reserveCapacity(
                        VisitorEnrollmentToolCallRouter.requiredSampleCount
                    )
                    for _ in 0..<VisitorEnrollmentToolCallRouter.requiredSampleCount {
                        try self.ensureEnrollmentGeneration(generation)
                        guard let embedding = try await self.captureEmbeddingWithoutGate() else {
                            return VisitorEnrollmentBeginResult.noUsableFace
                        }
                        try self.ensureEnrollmentGeneration(generation)
                        embeddings.append(embedding)
                    }

                    self.pendingEnrollment = PendingVisitorEnrollment(
                        consentedAt: consentedAt,
                        embeddings: embeddings
                    )
                    return VisitorEnrollmentBeginResult.samplesCaptured(embeddings.count)
                }
            }
            try ensureEnrollmentGeneration(generation)
            return result
        } catch let cancellation as CancellationError {
            pendingEnrollment = nil
            throw cancellation
        } catch {
            pendingEnrollment = nil
            if Task.isCancelled || generation != enrollmentGeneration {
                throw CancellationError()
            }
            throw IdentityCalibrationError.failed
        }
    }

    public func complete(
        memberID: MemberID,
        address: VoiceMemberAddress,
        completedAt: Date
    ) async throws {
        guard
            let pendingEnrollment,
            let visitorEnrollmentStore,
            completedAt.timeIntervalSinceReferenceDate.isFinite,
            pendingEnrollment.embeddings.count
                == VisitorEnrollmentToolCallRouter.requiredSampleCount
        else {
            throw IdentityCalibrationError.failed
        }

        do {
            try Task.checkCancellation()
            try await visitorEnrollmentStore.commitVisitorEnrollment(
                memberID: memberID,
                address: address,
                consentedAt: pendingEnrollment.consentedAt,
                completedAt: completedAt,
                embeddings: pendingEnrollment.embeddings
            )
            // A committed transaction wins a cancellation race. Clearing the
            // in-memory value prevents a caller from duplicating the write.
            self.pendingEnrollment = nil
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw IdentityCalibrationError.failed
        }
    }

    public func cancel() async {
        enrollmentGeneration &+= 1
        pendingEnrollment = nil
    }

    public func address(for memberID: MemberID) async throws -> VoiceMemberAddress? {
        guard let visitorEnrollmentStore else {
            throw IdentityCalibrationError.failed
        }
        do {
            try Task.checkCancellation()
            let address = try await visitorEnrollmentStore.address(for: memberID)
            try Task.checkCancellation()
            return address
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw IdentityCalibrationError.failed
        }
    }

    public func startCamera() async throws {
        var lease: IdentityCalibrationCameraLeaseCoordinator.Lease?
        do {
            try Task.checkCancellation()
            let acquiredLease = try await cameraLeaseCoordinator.acquire()
            lease = acquiredLease
            try Task.checkCancellation()
            manuallyHeldCameraLeases.append(acquiredLease)
        } catch let cancellation as CancellationError {
            if let lease {
                await cameraLeaseCoordinator.release(lease)
            }
            throw cancellation
        } catch {
            if Task.isCancelled {
                if let lease {
                    await cameraLeaseCoordinator.release(lease)
                }
                throw CancellationError()
            }
            if let lease {
                await cameraLeaseCoordinator.release(lease)
            }
            throw IdentityCalibrationError.failed
        }
    }

    public func stopCamera() async {
        guard let lease = manuallyHeldCameraLeases.popLast() else { return }
        await cameraLeaseCoordinator.release(lease)
    }

    /// Maps the current camera generation's transient BGRA frames into the
    /// Application value. The bridge is bounded and has no Vision/Core ML
    /// work; canceling the returned stream cancels the bridge task.
    public func previewFrames() async -> AsyncStream<IdentityCalibrationPreviewFrame> {
        let sourceStream = await frameSource.previewFrames()
        let pair = AsyncStream<IdentityCalibrationPreviewFrame>.makeStream(
            of: IdentityCalibrationPreviewFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let bridge = Task {
            for await frame in sourceStream {
                if Task.isCancelled { break }
                _ = pair.continuation.yield(Self.makePreview(from: frame))
            }
            pair.continuation.finish()
        }
        pair.continuation.onTermination = { @Sendable _ in
            bridge.cancel()
        }
        return pair.stream
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

    /// Presence needs only a fresh usable face. It deliberately avoids the
    /// SQLite gallery query and 800-member cosine ranking used by recognition.
    public func captureUsableFace() async throws -> Bool {
        do {
            try Task.checkCancellation()
            let embedding = try await capturePresenceEmbedding()
            try Task.checkCancellation()
            return embedding != nil
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch IdentityCalibrationCaptureError.busy {
            // Presence owns no semantic side effect. A regular diagnostic
            // capture that is already in flight is simply an absent sample;
            // the monitor will retry without tearing down its camera lease.
            return false
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
        try await withCaptureSlot {
            try await self.captureEmbeddingWithoutGate()
        }
    }

    private func capturePresenceEmbedding() async throws -> FaceEmbedding? {
        try await withPresenceCaptureSlot {
            try await self.captureEmbeddingWithoutGate()
        }
    }

    private func captureEmbeddingWithoutGate() async throws -> FaceEmbedding? {
        let frame = try await self.frameSource.nextFrame()
        try Task.checkCancellation()
        return try await self.embeddingPipeline.embedding(for: frame)
    }

    private func ensureEnrollmentGeneration(_ generation: UInt64) throws {
        guard generation == enrollmentGeneration, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func captureEmbedding(from imageURL: URL) async throws -> FaceEmbedding? {
        try await withCaptureSlot {
            let frame = try await self.photoFrameSource.frame(from: imageURL)
            try Task.checkCancellation()
            return try await self.embeddingPipeline.embedding(for: frame)
        }
    }

    private func captureEmbedding(
        from photo: IdentityCalibrationPhoto
    ) async throws -> FaceEmbedding? {
        try await withCaptureSlot {
            let frame = try await self.photoFrameSource.frame(from: photo)
            try Task.checkCancellation()
            return try await self.embeddingPipeline.embedding(for: frame)
        }
    }

    private func withCaptureSlot<T: Sendable>(
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        guard let permit = await captureGate.tryAcquire() else {
            throw IdentityCalibrationCaptureError.busy
        }
        do {
            let result = try await operation()
            await captureGate.release(permit)
            return result
        } catch {
            await captureGate.release(permit)
            throw error
        }
    }

    private func withPresenceCaptureSlot<T: Sendable>(
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        let permit = try await captureGate.acquirePresence()
        do {
            let result = try await operation()
            await captureGate.release(permit)
            return result
        } catch {
            await captureGate.release(permit)
            throw error
        }
    }

    private func withEnrollmentCaptureSlot<T: Sendable>(
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        let permit = try await captureGate.acquireEnrollment()
        do {
            let result = try await operation()
            await captureGate.release(permit)
            return result
        } catch {
            await captureGate.release(permit)
            throw error
        }
    }

    private func withCameraLease<T: Sendable>(
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        let lease = try await cameraLeaseCoordinator.acquire()
        do {
            let result = try await operation()
            await cameraLeaseCoordinator.release(lease)
            return result
        } catch {
            await cameraLeaseCoordinator.release(lease)
            throw error
        }
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

    private static func makePreview(
        from frame: CameraFrame
    ) -> IdentityCalibrationPreviewFrame {
        IdentityCalibrationPreviewFrame(
            bgraBytes: frame.bytes,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow
        )
    }
}

private enum IdentityCalibrationCaptureError: Error {
    case busy
}

/// Coordinates ownership of the shared camera stream. The start task is a
/// single-flight operation: concurrent leases await the same underlying
/// `frameSource.start()` and only the final lease releases the stream.
private actor IdentityCalibrationCameraLeaseCoordinator {
    struct Lease: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    private struct StopOperation: Sendable {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private let frameSource: any IdentityCalibrationFrameSource
    private var activeLeaseIDs: Set<UInt64> = []
    private var pendingAcquireCount = 0
    private var nextLeaseID: UInt64 = 0
    private var startTask: Task<Void, Error>?
    private var nextStopGeneration: UInt64 = 0
    private var stopOperation: StopOperation?

    init(frameSource: any IdentityCalibrationFrameSource) {
        self.frameSource = frameSource
    }

    func acquire() async throws -> Lease {
        try Task.checkCancellation()

        if let stopOperation {
            await stopOperation.task.value
            clearStopOperation(generation: stopOperation.generation)
        }
        try Task.checkCancellation()

        pendingAcquireCount += 1

        let taskToAwait: Task<Void, Error>?
        if activeLeaseIDs.isEmpty {
            if let startTask {
                taskToAwait = startTask
            } else {
                let frameSource = frameSource
                let task = Task<Void, Error> {
                    try await frameSource.start()
                }
                startTask = task
                taskToAwait = task
            }
        } else {
            taskToAwait = nil
        }

        do {
            if let taskToAwait {
                try await taskToAwait.value
                try Task.checkCancellation()
                startTask = nil
            }

            pendingAcquireCount -= 1
            nextLeaseID &+= 1
            let lease = Lease(id: nextLeaseID)
            activeLeaseIDs.insert(lease.id)
            return lease
        } catch {
            pendingAcquireCount -= 1
            if pendingAcquireCount == 0, activeLeaseIDs.isEmpty {
                let taskToCancel = startTask
                startTask = nil
                taskToCancel?.cancel()
                await stopCameraStream()
            }
            throw error
        }
    }

    func release(_ lease: Lease) async {
        guard activeLeaseIDs.remove(lease.id) != nil else { return }
        guard activeLeaseIDs.isEmpty, pendingAcquireCount == 0, startTask == nil else {
            return
        }
        await stopCameraStream()
    }

    private func stopCameraStream() async {
        if let stopOperation {
            await stopOperation.task.value
            clearStopOperation(generation: stopOperation.generation)
            return
        }

        let frameSource = frameSource
        nextStopGeneration &+= 1
        let generation = nextStopGeneration
        let task = Task<Void, Never> {
            await frameSource.stop()
        }
        stopOperation = StopOperation(generation: generation, task: task)
        await task.value
        clearStopOperation(generation: generation)
    }

    private func clearStopOperation(generation: UInt64) {
        guard stopOperation?.generation == generation else { return }
        stopOperation = nil
    }
}

/// Serializes fresh-frame and embedding work while allowing a long-running
/// presence monitor to share the same camera service with enrollment or
/// recognition. Regular diagnostic captures fail closed when occupied, while
/// presence waits and enrollment receives priority over queued presence work.
private actor IdentityCalibrationCaptureGate {
    struct Permit: Sendable {}

    private enum WaiterKind: Equatable {
        case enrollment
        case presence
    }

    private struct Waiter {
        let id: UInt64
        let kind: WaiterKind
        let continuation: CheckedContinuation<Permit, Error>
    }

    private var held = false
    private var nextWaiterID: UInt64 = 0
    private var waiters: [Waiter] = []
    private var enrollmentWaiterID: UInt64?

    func tryAcquire() -> Permit? {
        guard !held, waiters.isEmpty, enrollmentWaiterID == nil else {
            return nil
        }
        held = true
        return Permit()
    }

    func acquirePresence() async throws -> Permit {
        try await acquire(kind: .presence)
    }

    func acquireEnrollment() async throws -> Permit {
        guard enrollmentWaiterID == nil else {
            throw IdentityCalibrationError.failed
        }
        return try await acquire(kind: .enrollment)
    }

    func release(_: Permit) {
        if let index = waiters.firstIndex(where: { $0.kind == .enrollment }) {
            let waiter = waiters.remove(at: index)
            enrollmentWaiterID = nil
            waiter.continuation.resume(returning: Permit())
            return
        }

        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: Permit())
            return
        }

        held = false
    }

    private func acquire(kind: WaiterKind) async throws -> Permit {
        if !held, waiters.isEmpty, enrollmentWaiterID == nil {
            held = true
            return Permit()
        }

        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        if kind == .enrollment {
            enrollmentWaiterID = waiterID
        }

        var receivedPermit = false
        do {
            let permit = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Permit, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters.append(Waiter(
                            id: waiterID,
                            kind: kind,
                            continuation: continuation
                        ))
                    }
                }
            }, onCancel: {
                Task { [weak self] in
                    await self?.cancel(waiterID: waiterID)
                }
            })
            receivedPermit = true
            try Task.checkCancellation()
            return permit
        } catch {
            if receivedPermit {
                release(Permit())
            } else {
                cancel(waiterID: waiterID)
            }
            throw error
        }
    }

    private func cancel(waiterID: UInt64) {
        if let index = waiters.firstIndex(where: { $0.id == waiterID }) {
            let waiter = waiters.remove(at: index)
            if waiter.kind == .enrollment {
                enrollmentWaiterID = nil
            }
            waiter.continuation.resume(throwing: CancellationError())
            return
        }

        // Cancellation can happen before the continuation is appended.
        if enrollmentWaiterID == waiterID {
            enrollmentWaiterID = nil
        }
    }
}

private struct PendingVisitorEnrollment: Sendable {
    let consentedAt: Date
    let embeddings: [FaceEmbedding]
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
                store: store,
                visitorEnrollmentStore: store
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
extension SQLiteFaceEmbeddingStore: VisitorEnrollmentStore {}
#endif

extension SFaceFrameEmbeddingPipeline: IdentityCalibrationEmbeddingProducing {}
extension CameraCaptureAdapter: IdentityCalibrationCameraAdapter {}

#endif
