import Foundation
import LumiApplication
import LumiDomain
@testable import LumiInfrastructure
import Testing

@Suite("Core ML identity calibration service")
struct CoreMLIdentityCalibrationServiceTests {
    @Test("identity diagnostics are fixed payload-free categories")
    func identityDiagnosticsArePayloadFree() {
        let events = IdentityDiagnosticEvent.allCases

        #expect(Set(events.map(\.rawValue)).count == events.count)
        for event in events {
            #expect(Mirror(reflecting: event).children.isEmpty)
        }
    }

    @Test("enrolled member count deduplicates multiple face samples per member")
    func enrolledMemberCountDeduplicatesSamples() async throws {
        let firstMember = try MemberID(rawValue: "member-a")
        let secondMember = try MemberID(rawValue: "member-b")
        let store = RecordingCalibrationStore()
        await store.seed([
            StoredFaceEmbeddingSample(
                memberID: firstMember,
                embedding: try makeEmbedding(axis: 0)
            ),
            StoredFaceEmbeddingSample(
                memberID: firstMember,
                embedding: try makeEmbedding(axis: 1)
            ),
            StoredFaceEmbeddingSample(
                memberID: secondMember,
                embedding: try makeEmbedding(axis: 2)
            ),
        ])
        let service = CoreMLIdentityCalibrationService(
            frameSource: PreviewingCalibrationFrameSource(),
            embeddingPipeline: RecordingCalibrationEmbeddingPipeline(
                .success(try makeEmbedding(axis: 0))
            ),
            store: store
        )

        #expect(try await service.enrolledMemberCount() == 2)
        #expect(await store.sFaceSamplesCallCount == 1)
    }

    @Test("concrete camera source discards a buffered frame before arming")
    func concreteFrameSourceDiscardsBufferedFrame() async throws {
        let adapter = BufferedCameraAdapter()
        let source = IdentityCalibrationCameraFrameSource(adapter: adapter)
        try await source.start()
        let stale = try makeFrame(byte: 1)
        let fresh = try makeFrame(byte: 2)
        await adapter.send(stale)

        let task = Task { try await source.nextFrame() }
        await source.waitForFreshFrameRequest()
        await adapter.send(fresh)

        #expect(try await task.value == fresh)
        await source.stop()
    }

    @Test("stopping concrete camera source cancels its pending fresh frame")
    func concreteFrameSourceStopCancelsPendingFrame() async throws {
        let adapter = BufferedCameraAdapter()
        let source = IdentityCalibrationCameraFrameSource(adapter: adapter)
        try await source.start()
        await adapter.send(try makeFrame(byte: 1))

        let task = Task { try await source.nextFrame() }
        await source.waitForFreshFrameRequest()
        await source.stop()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("concrete camera source publishes the newest preview frame")
    func concretePreviewUsesNewestFrame() async throws {
        let adapter = BufferedCameraAdapter()
        let source = IdentityCalibrationCameraFrameSource(adapter: adapter)
        try await source.start()
        let previewStream = await source.previewFrames()
        var iterator = previewStream.makeAsyncIterator()

        let first = try makeFrame(byte: 1)
        let second = try makeFrame(byte: 2)
        let newest = try makeFrame(byte: 3)

        await adapter.send(first)
        await source.waitForPreviewDelivery()
        #expect(await iterator.next() == first)

        await adapter.send(second)
        await source.waitForPreviewDelivery()
        await adapter.send(newest)
        await source.waitForPreviewDelivery()
        #expect(await iterator.next() == newest)

        await source.stop()
    }

    @Test("preview delivery does not consume the fresh capture frame")
    func previewDoesNotConsumeFreshCapture() async throws {
        let adapter = BufferedCameraAdapter()
        let source = IdentityCalibrationCameraFrameSource(adapter: adapter)
        try await source.start()
        let previewStream = await source.previewFrames()
        var previewIterator = previewStream.makeAsyncIterator()

        let stale = try makeFrame(byte: 4)
        let fresh = try makeFrame(byte: 5)
        await adapter.send(stale)
        await source.waitForPreviewDelivery()
        #expect(await previewIterator.next() == stale)

        let capture = Task { try await source.nextFrame() }
        await source.waitForFreshFrameRequest()
        await adapter.send(fresh)
        await source.waitForPreviewDelivery()

        #expect(try await capture.value == fresh)
        #expect(await previewIterator.next() == fresh)
        await source.stop()
    }

    @Test("concrete preview stream finishes on stop and isolates restart generations")
    func concretePreviewStopAndRestartUseIndependentGenerations() async throws {
        let adapter = RestartableBufferedCameraAdapter()
        let source = IdentityCalibrationCameraFrameSource(adapter: adapter)
        try await source.start()
        let oldStream = await source.previewFrames()
        var oldIterator = oldStream.makeAsyncIterator()
        let oldFrame = try makeFrame(byte: 6)
        await adapter.send(oldFrame)
        await source.waitForPreviewDelivery()
        #expect(await oldIterator.next() == oldFrame)

        await source.stop()
        #expect(await oldIterator.next() == nil)

        try await source.start()
        let newStream = await source.previewFrames()
        var newIterator = newStream.makeAsyncIterator()
        let newFrame = try makeFrame(byte: 7)
        await adapter.send(newFrame)
        await source.waitForPreviewDelivery()

        #expect(await oldIterator.next() == nil)
        #expect(await newIterator.next() == newFrame)
        await source.stop()
    }

    @Test("service maps transient camera preview without running embedding inference")
    func serviceMapsPreviewWithoutInference() async throws {
        let source = PreviewingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )

        try await service.startCamera()
        let previewStream = await service.previewFrames()
        var iterator = previewStream.makeAsyncIterator()
        let frame = try CameraFrame(
            bytes: Data([0x11, 0x22, 0x33, 0xFF, 0x44, 0x55, 0x66, 0xFF]),
            width: 2,
            height: 1,
            bytesPerRow: 8,
            orientation: .upright
        )

        await source.sendPreview(frame)

        guard let preview = await iterator.next() else {
            Issue.record("expected one mapped preview frame")
            return
        }
        #expect(preview.bgraBytes == frame.bytes)
        #expect(preview.width == frame.width)
        #expect(preview.height == frame.height)
        #expect(preview.bytesPerRow == frame.bytesPerRow)
        #expect(await pipeline.callCount == 0)

        await service.stopCamera()
    }

    @Test("service preview stream finishes on stop and is independent after restart")
    func servicePreviewStopsAndRestartsByGeneration() async throws {
        let source = PreviewingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )

        try await service.startCamera()
        let firstStream = await service.previewFrames()
        var firstIterator = firstStream.makeAsyncIterator()
        await service.stopCamera()
        #expect(await firstIterator.next() == nil)

        try await service.startCamera()
        let secondStream = await service.previewFrames()
        var secondIterator = secondStream.makeAsyncIterator()
        let secondFrame = try makeFrame(byte: 9)
        await source.sendPreview(secondFrame)

        guard let preview = await secondIterator.next() else {
            Issue.record("expected preview after restart")
            return
        }
        #expect(preview.bgraBytes == secondFrame.bytes)
        await service.stopCamera()
    }

    @Test("service bridge cancels source consumption when preview consumer cancels")
    func servicePreviewBridgeTerminatesDeterministically() async throws {
        let source = TerminatingPreviewFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )

        try await service.startCamera()
        let previewStream = await service.previewFrames()
        let consumer = Task {
            for await _ in previewStream {
                if Task.isCancelled { return }
            }
        }
        await source.waitForPreviewConsumer()

        consumer.cancel()
        _ = await consumer.value
        await source.waitForPreviewConsumerTermination()

        #expect(await source.previewConsumerTerminated)
        await service.stopCamera()
    }

    @Test("service returns a finished preview stream before camera start")
    func servicePreviewIsFinishedBeforeStart() async throws {
        let source = RecordingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )

        var iterator = (await service.previewFrames()).makeAsyncIterator()

        #expect(await iterator.next() == nil)
        #expect(await source.startCallCount == 0)
        #expect(await pipeline.callCount == 0)
    }

    @Test("concurrent camera leases share one delayed start and stop after the last release")
    func concurrentCameraLeasesAreSingleFlight() async throws {
        let source = DelayedStartCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(.noUsableFace)
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )

        let first = Task { try await service.startCamera() }
        await source.waitForStartCall(count: 1)

        let second = Task { try await service.startCamera() }
        for _ in 0..<64 { await Task.yield() }
        #expect(await source.startCallCount == 1)

        await source.releaseStarts()
        try await first.value
        try await second.value

        await service.stopCamera()
        #expect(await source.stopCallCount == 0)
        await service.stopCamera()
        #expect(await source.stopCallCount == 1)
    }

    @Test("cancelled camera acquisition does not release another owner's lease")
    func cancelledCameraAcquisitionDoesNotReleaseAnotherLease() async throws {
        let source = DelayedStartCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(.noUsableFace)
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )

        let owner = Task { try await service.startCamera() }
        await source.waitForStartCall(count: 1)
        await source.releaseStarts()
        try await owner.value

        let cancelled = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            try await service.startCamera()
        }
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(await source.stopCallCount == 0)

        await service.stopCamera()
        #expect(await source.stopCallCount == 1)
    }

    @Test("a new camera lease waits for a delayed stop before restarting")
    func cameraLeaseSerializesStopAndNextStart() async throws {
        let source = DelayedStopCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(.noUsableFace)
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )

        try await service.startCamera()
        let stop = Task { await service.stopCamera() }
        await source.waitForStopCall()

        let next = Task { try await service.startCamera() }
        for _ in 0..<64 { await Task.yield() }
        #expect(await source.startCallCount == 1)

        await source.releaseStop()
        _ = await stop.value
        try await next.value
        #expect(await source.startCallCount == 2)

        await service.stopCamera()
        #expect(await source.stopCallCount == 2)
    }

    @Test("one enrollment capture consumes exactly the next frame and ignores stale frames")
    func enrollmentUsesFreshFrame() async throws {
        let source = RecordingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(.success(try makeEmbedding(axis: 0)))
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )
        let memberID = try MemberID(rawValue: "temporary-a")
        let stale = try makeFrame(byte: 1)
        let fresh = try makeFrame(byte: 2)

        try await service.startCamera()
        await source.send(stale)

        let task = Task {
            try await service.captureEnrollmentSample(
                for: memberID,
                at: Date(timeIntervalSince1970: 100)
            )
        }
        await source.waitForNextFrameRequest()
        await source.send(fresh)

        #expect(try await task.value == .stored)
        #expect(await source.nextFrameCallCount == 1)
        #expect(await pipeline.callCount == 1)
        #expect(await store.savedMemberIDs == [memberID])
        #expect(await store.savedDates == [Date(timeIntervalSince1970: 100)])
    }

    @Test("photo enrollment uses the imported frame without starting the camera")
    func photoEnrollmentUsesPhotoSource() async throws {
        let cameraSource = RecordingCalibrationFrameSource()
        let photoSource = RecordingCalibrationPhotoFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: cameraSource,
            embeddingPipeline: pipeline,
            store: store,
            photoFrameSource: photoSource
        )
        let memberID = try MemberID(rawValue: "temporary-photo")
        let imageURL = URL(fileURLWithPath: "/tmp/imported.jpg")

        #expect(try await service.captureEnrollmentPhoto(
            for: memberID,
            from: imageURL,
            at: Date(timeIntervalSince1970: 200)
        ) == .stored)
        #expect(await cameraSource.startCallCount == 0)
        #expect(await cameraSource.nextFrameCallCount == 0)
        #expect(await photoSource.receivedURLs == [imageURL])
        #expect(await store.savedMemberIDs == [memberID])
        #expect(await pipeline.callCount == 1)
    }

    @Test("Data photo enrollment forwards encoded payload without starting camera")
    func dataPhotoEnrollmentUsesPhotoSource() async throws {
        let cameraSource = RecordingCalibrationFrameSource()
        let photoSource = RecordingCalibrationPhotoFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: cameraSource,
            embeddingPipeline: pipeline,
            store: store,
            photoFrameSource: photoSource
        )
        let memberID = try MemberID(rawValue: "temporary-data-photo")
        let payload = IdentityCalibrationPhoto(data: Data([0x01, 0x02]))

        #expect(try await service.captureEnrollmentPhoto(
            for: memberID,
            from: payload,
            at: Date(timeIntervalSince1970: 203)
        ) == .stored)
        #expect(await cameraSource.startCallCount == 0)
        #expect(await photoSource.receivedPhotos == [payload])
        #expect(await store.savedMemberIDs == [memberID])
    }

    @Test("photo enrollment no usable face never writes a sample")
    func photoEnrollmentNoUsableFaceDoesNotSave() async throws {
        let cameraSource = RecordingCalibrationFrameSource()
        let photoSource = RecordingCalibrationPhotoFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(.noUsableFace)
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: cameraSource,
            embeddingPipeline: pipeline,
            store: store,
            photoFrameSource: photoSource
        )
        let memberID = try MemberID(rawValue: "temporary-photo")

        #expect(try await service.captureEnrollmentPhoto(
            for: memberID,
            from: URL(fileURLWithPath: "/tmp/no-face.png"),
            at: Date(timeIntervalSince1970: 201)
        ) == .noUsableFace)
        #expect(await cameraSource.startCallCount == 0)
        #expect(await cameraSource.nextFrameCallCount == 0)
        #expect(await pipeline.callCount == 1)
        #expect(await store.saveCallCount == 0)
    }

    @Test("photo return ranks the full gallery, never saves, and never starts camera")
    func photoReturnUsesFullGalleryWithoutCamera() async throws {
        let cameraSource = RecordingCalibrationFrameSource()
        let photoSource = RecordingCalibrationPhotoFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = RecordingCalibrationStore()
        let memberA = try MemberID(rawValue: "temporary-photo-a")
        let memberB = try MemberID(rawValue: "temporary-photo-b")
        await store.seed([
            try StoredFaceEmbeddingSample(
                memberID: memberA,
                embedding: makeEmbedding(axis: 0)
            ),
            try StoredFaceEmbeddingSample(
                memberID: memberB,
                embedding: makeEmbedding(axis: 1)
            )
        ])
        let service = CoreMLIdentityCalibrationService(
            frameSource: cameraSource,
            embeddingPipeline: pipeline,
            store: store,
            photoFrameSource: photoSource
        )

        guard case let .measured(evidence) = try await service.captureReturnVisitPhoto(
            from: URL(fileURLWithPath: "/tmp/return.heic")
        ) else {
            Issue.record("expected measured photo evidence")
            return
        }
        #expect(evidence.gallerySampleCount == 2)
        #expect(evidence.top1?.memberID == memberA)
        #expect(evidence.top2?.memberID == memberB)
        #expect(await cameraSource.startCallCount == 0)
        #expect(await cameraSource.nextFrameCallCount == 0)
        #expect(await store.saveCallCount == 0)
        #expect(await photoSource.receivedURLs == [URL(fileURLWithPath: "/tmp/return.heic")])
    }

    @Test("camera and photo captures share one in-flight guard")
    func cameraAndPhotoCaptureCannotOverlap() async throws {
        let cameraSource = RecordingCalibrationFrameSource()
        let photoSource = SuspendedCalibrationPhotoFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: cameraSource,
            embeddingPipeline: pipeline,
            store: store,
            photoFrameSource: photoSource
        )
        let memberID = try MemberID(rawValue: "temporary-photo")
        let photo = Task {
            try await service.captureEnrollmentPhoto(
                for: memberID,
                from: URL(fileURLWithPath: "/tmp/in-flight.jpg"),
                at: Date(timeIntervalSince1970: 202)
            )
        }
        await photoSource.waitForFrameRequest()

        await #expect(throws: IdentityCalibrationError.failed) {
            _ = try await service.captureEnrollmentSample(
                for: memberID,
                at: Date(timeIntervalSince1970: 203)
            )
        }
        #expect(await cameraSource.nextFrameCallCount == 0)
        await photoSource.release(try makeFrame(byte: 3))
        #expect(try await photo.value == .stored)
    }

    @Test("photo decoder cancellation preserves error and skips pipeline and store")
    func photoDecoderCancellationPreservesCancellation() async throws {
        let cameraSource = RecordingCalibrationFrameSource()
        let photoSource = RecordingCalibrationPhotoFrameSource()
        await photoSource.setFailure(CancellationError())
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: cameraSource,
            embeddingPipeline: pipeline,
            store: store,
            photoFrameSource: photoSource
        )

        await #expect(throws: CancellationError.self) {
            _ = try await service.captureReturnVisitPhoto(
                from: URL(fileURLWithPath: "/tmp/cancel.jpg")
            )
        }
        #expect(await pipeline.callCount == 0)
        #expect(await store.saveCallCount == 0)
    }

    @Test("generic photo decoder failure is redacted and skips downstream work")
    func genericPhotoDecoderFailureIsRedacted() async throws {
        let cameraSource = RecordingCalibrationFrameSource()
        let photoSource = RecordingCalibrationPhotoFrameSource()
        await photoSource.setFailure(MarkerError.marker)
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: cameraSource,
            embeddingPipeline: pipeline,
            store: store,
            photoFrameSource: photoSource
        )

        do {
            _ = try await service.captureEnrollmentPhoto(
                for: try MemberID(rawValue: "temporary-photo"),
                from: URL(fileURLWithPath: "/tmp/failure.jpg"),
                at: Date(timeIntervalSince1970: 204)
            )
            Issue.record("expected calibration failure")
        } catch let error as IdentityCalibrationError {
            #expect(error == .failed)
            #expect(String(reflecting: error).contains("marker") == false)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await pipeline.callCount == 0)
        #expect(await store.saveCallCount == 0)
    }

    @Test("nonfinite photo enrollment date fails before decoding")
    func nonfinitePhotoEnrollmentDateFailsBeforeDecoder() async throws {
        let cameraSource = RecordingCalibrationFrameSource()
        let photoSource = RecordingCalibrationPhotoFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: cameraSource,
            embeddingPipeline: pipeline,
            store: store,
            photoFrameSource: photoSource
        )

        await #expect(throws: IdentityCalibrationError.failed) {
            _ = try await service.captureEnrollmentPhoto(
                for: try MemberID(rawValue: "temporary-photo"),
                from: URL(fileURLWithPath: "/tmp/nonfinite.jpg"),
                at: Date(timeIntervalSinceReferenceDate: .nan)
            )
        }
        #expect(await photoSource.receivedURLs.isEmpty)
        #expect(await pipeline.callCount == 0)
        #expect(await store.saveCallCount == 0)
    }

    @Test("concurrent capture operations fail closed and only one frame is consumed")
    func onlyOneCaptureInFlight() async throws {
        let source = RecordingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(.success(try makeEmbedding(axis: 0)))
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )
        let memberID = try MemberID(rawValue: "temporary-a")
        try await service.startCamera()

        let first = Task {
            try await service.captureEnrollmentSample(
                for: memberID,
                at: Date(timeIntervalSince1970: 100)
            )
        }
        await source.waitForNextFrameRequest()

        await #expect(throws: IdentityCalibrationError.failed) {
            _ = try await service.captureReturnVisit()
        }
        await source.send(try makeFrame(byte: 2))
        #expect(try await first.value == .stored)
        #expect(await source.nextFrameCallCount == 1)
    }

    @Test("stopping camera cancels a pending fresh-frame capture")
    func stopCancelsPendingCapture() async throws {
        let source = RecordingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(.success(try makeEmbedding(axis: 0)))
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )
        try await service.startCamera()

        let task = Task {
            try await service.captureReturnVisit()
        }
        await source.waitForNextFrameRequest()
        await service.stopCamera()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await pipeline.callCount == 0)
    }

    @Test("cancelling a pending fresh-frame capture preserves CancellationError")
    func cancellingPendingCapturePreservesCancellation() async throws {
        let source = RecordingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )
        try await service.startCamera()

        let task = Task {
            try await service.captureReturnVisit()
        }
        await source.waitForNextFrameRequest()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await pipeline.callCount == 0)
    }

    @Test("pre-cancel skips camera, pipeline, and store")
    func preCancellationSkipsDependencies() async throws {
        let source = RecordingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(.success(try makeEmbedding(axis: 0)))
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )
        let memberID = try MemberID(rawValue: "temporary-a")

        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            _ = try await service.captureEnrollmentSample(
                for: memberID,
                at: Date(timeIntervalSince1970: 100)
            )
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await source.startCallCount == 0)
        #expect(await source.nextFrameCallCount == 0)
        #expect(await pipeline.callCount == 0)
        #expect(await store.saveCallCount == 0)
    }

    @Test("no usable face never writes a sample")
    func noUsableFaceDoesNotSave() async throws {
        let source = RecordingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(.noUsableFace)
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )
        let memberID = try MemberID(rawValue: "temporary-a")
        try await service.startCamera()

        let task = Task {
            try await service.captureEnrollmentSample(
                for: memberID,
                at: Date(timeIntervalSince1970: 100)
            )
        }
        await source.waitForNextFrameRequest()
        await source.send(try makeFrame(byte: 2))

        #expect(try await task.value == .noUsableFace)
        #expect(await store.saveCallCount == 0)
    }

    @Test("generic pipeline failure is redacted and does not save")
    func pipelineFailureIsRedacted() async throws {
        let source = RecordingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(.failure)
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )
        let memberID = try MemberID(rawValue: "temporary-a")
        try await service.startCamera()

        let task = Task {
            try await service.captureEnrollmentSample(
                for: memberID,
                at: Date(timeIntervalSince1970: 100)
            )
        }
        await source.waitForNextFrameRequest()
        await source.send(try makeFrame(byte: 2))

        do {
            _ = try await task.value
            Issue.record("expected calibration failure")
        } catch let error as IdentityCalibrationError {
            #expect(error == .failed)
            #expect(String(describing: error) == "Identity calibration failed.")
            #expect(!String(reflecting: error).contains("marker"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await store.saveCallCount == 0)
    }

    @Test("generic store failure is redacted and does not report success")
    func storeFailureIsRedacted() async throws {
        let source = RecordingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = FailingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )
        let memberID = try MemberID(rawValue: "temporary-a")
        try await service.startCamera()

        let task = Task {
            try await service.captureEnrollmentSample(
                for: memberID,
                at: Date(timeIntervalSince1970: 100)
            )
        }
        await source.waitForNextFrameRequest()
        await source.send(try makeFrame(byte: 2))

        do {
            _ = try await task.value
            Issue.record("expected calibration failure")
        } catch let error as IdentityCalibrationError {
            #expect(error == .failed)
            #expect(String(describing: error) == "Identity calibration failed.")
            #expect(!String(reflecting: error).contains("marker"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("return visit ranks the full gallery and exposes only candidate IDs and scores")
    func returnVisitRanksFullGallery() async throws {
        let source = RecordingCalibrationFrameSource()
        let query = try makeEmbedding(axis: 0)
        let pipeline = RecordingCalibrationEmbeddingPipeline(.success(query))
        let store = RecordingCalibrationStore()
        let memberA = try MemberID(rawValue: "temporary-a")
        let memberB = try MemberID(rawValue: "temporary-b")
        await store.seed([
            try StoredFaceEmbeddingSample(
                memberID: memberA,
                embedding: makeEmbedding(axis: 0)
            ),
            StoredFaceEmbeddingSample(
                memberID: memberB,
                embedding: try FaceEmbedding(
                    modelVersion: SFaceEmbeddingRecordCodec.modelVersion,
                    components: [0.8, 0.6] + Array(repeating: 0, count: 126)
                )
            )
        ])
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )
        try await service.startCamera()

        let task = Task { try await service.captureReturnVisit() }
        await source.waitForNextFrameRequest()
        await source.send(try makeFrame(byte: 2))

        guard case let .measured(evidence) = try await task.value else {
            Issue.record("expected measured calibration evidence")
            return
        }
        #expect(evidence.gallerySampleCount == 2)
        #expect(evidence.top1?.memberID == memberA)
        #expect(evidence.top1?.cosineSimilarity == 1)
        #expect(evidence.top2?.memberID == memberB)
        #expect(abs((evidence.top2?.cosineSimilarity ?? 0) - 0.8) < 0.000_001)
        #expect(abs((evidence.margin ?? 0) - 0.2) < 0.000_001)
        #expect(await store.saveCallCount == 0)
    }

    @Test("presence capture checks only the fresh face and never queries the gallery")
    func presenceCaptureSkipsGallery() async throws {
        let source = RecordingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(
            .success(try makeEmbedding(axis: 0))
        )
        let store = RecordingCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )
        try await service.startCamera()

        let task = Task { try await service.captureUsableFace() }
        await source.waitForNextFrameRequest()
        await source.send(try makeFrame(byte: 3))

        #expect(try await task.value)
        #expect(await pipeline.callCount == 1)
        #expect(await store.sFaceSamplesCallCount == 0)
    }

    @Test("reset deletes only the selected temporary member")
    func resetIsScopedToSelectedMember() async throws {
        let source = RecordingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(.noUsableFace)
        let store = RecordingCalibrationStore()
        let memberA = try MemberID(rawValue: "temporary-a")
        let memberB = try MemberID(rawValue: "temporary-b")
        await store.seed([
            try StoredFaceEmbeddingSample(memberID: memberA, embedding: makeEmbedding(axis: 0)),
            try StoredFaceEmbeddingSample(memberID: memberB, embedding: makeEmbedding(axis: 1))
        ])
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )

        try await service.reset(for: memberA)

        #expect(try await service.sampleCount(for: memberA) == 0)
        #expect(try await service.sampleCount(for: memberB) == 1)
        #expect(await store.deletedMemberIDs == [memberA])
    }

    @Test("a committed save returns stored even when cancellation arrives during save")
    func committedSaveWinsCancellationRace() async throws {
        let source = RecordingCalibrationFrameSource()
        let pipeline = RecordingCalibrationEmbeddingPipeline(.success(try makeEmbedding(axis: 0)))
        let store = CommitOnCancellationCalibrationStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: source,
            embeddingPipeline: pipeline,
            store: store
        )
        let memberID = try MemberID(rawValue: "temporary-a")
        try await service.startCamera()

        let task = Task {
            try await service.captureEnrollmentSample(
                for: memberID,
                at: Date(timeIntervalSince1970: 100)
            )
        }
        await source.waitForNextFrameRequest()
        await source.send(try makeFrame(byte: 2))
        await store.waitForSaveStart()
        task.cancel()

        #expect(try await task.value == .stored)
        #expect(await store.committed)
    }

    @Test("factory rejects non-bundled model URLs without compiling or downloading")
    func factoryRejectsInvalidURLs() async {
        let diagnostics = IdentityFactoryDiagnosticRecorder()
        let invalidSFace = URL(fileURLWithPath: "/tmp/not-sface.mlmodelc")
        let invalidYuNet = URL(fileURLWithPath: "/tmp/not-yunet.mlmodelc")
        let database = URL(fileURLWithPath: "/tmp/identity-calibration.sqlite")

        await #expect(throws: IdentityCalibrationError.failed) {
            _ = try await CoreMLIdentityCalibrationFactory.load(
                sFaceModelURL: invalidSFace,
                yuNetModelURL: invalidYuNet,
                databaseURL: database,
                diagnosticSink: diagnostics.record
            )
        }
        #expect(diagnostics.events == [
            .identityFactoryLoadStarted,
            .identityFactoryFailedInvalidModelResources,
        ])
    }

    @Test("factory accepts only exact existing compiled model resource names")
    func factoryCompiledModelNameContract() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "identity-calibration-model-name-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let sFace = root.appendingPathComponent("SFace.mlmodelc", isDirectory: true)
        let yuNet = root.appendingPathComponent("YuNet.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sFace,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: yuNet,
            withIntermediateDirectories: false
        )

        #expect(CoreMLIdentityCalibrationFactory.isCompiledModelURL(
            sFace,
            expectedName: "SFace"
        ))
        #expect(CoreMLIdentityCalibrationFactory.isCompiledModelURL(
            yuNet,
            expectedName: "YuNet"
        ))
        #expect(!CoreMLIdentityCalibrationFactory.isCompiledModelURL(
            root.appendingPathComponent("Other.mlmodelc", isDirectory: true),
            expectedName: "SFace"
        ))
    }

    private func makeFrame(byte: UInt8) throws -> CameraFrame {
        try CameraFrame(
            bytes: Data([byte, byte, byte, 255]),
            width: 1,
            height: 1,
            bytesPerRow: 4,
            orientation: .upright
        )
    }

    private func makeEmbedding(axis: Int) throws -> FaceEmbedding {
        var components = Array(repeating: Float.zero, count: 128)
        components[axis] = 1
        return try FaceEmbedding(
            modelVersion: SFaceEmbeddingRecordCodec.modelVersion,
            components: components
        )
    }
}

private actor RecordingCalibrationPhotoFrameSource: IdentityCalibrationPhotoFrameSource {
    private(set) var receivedURLs: [URL] = []
    private(set) var receivedPhotos: [IdentityCalibrationPhoto] = []
    private var failure: Error?

    func frame(from imageURL: URL) async throws -> CameraFrame {
        receivedURLs.append(imageURL)
        if let failure {
            throw failure
        }
        return try CameraFrame(
            bytes: Data(repeating: 0, count: 4),
            width: 1,
            height: 1,
            bytesPerRow: 4,
            orientation: .upright
        )
    }

    func frame(from photo: IdentityCalibrationPhoto) async throws -> CameraFrame {
        receivedPhotos.append(photo)
        if let failure {
            throw failure
        }
        return try CameraFrame(
            bytes: Data(repeating: 0, count: 4),
            width: 1,
            height: 1,
            bytesPerRow: 4,
            orientation: .upright
        )
    }

    func setFailure(_ error: Error?) {
        failure = error
    }
}

private actor SuspendedCalibrationPhotoFrameSource: IdentityCalibrationPhotoFrameSource {
    private var pending: CheckedContinuation<CameraFrame, Error>?
    private var frameRequested = AsyncStream<Void>.makeStream(
        of: Void.self,
        bufferingPolicy: .bufferingNewest(1)
    )

    func frame(from imageURL: URL) async throws -> CameraFrame {
        _ = imageURL
        frameRequested.continuation.yield(())
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
        }
    }

    func frame(from photo: IdentityCalibrationPhoto) async throws -> CameraFrame {
        _ = photo
        frameRequested.continuation.yield(())
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
        }
    }

    func waitForFrameRequest() async {
        var iterator = frameRequested.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release(_ frame: CameraFrame) {
        pending?.resume(returning: frame)
        pending = nil
    }
}

private enum CalibrationEmbeddingResult: Sendable {
    case noUsableFace
    case success(FaceEmbedding)
    case failure
}

private actor RecordingCalibrationEmbeddingPipeline:
    IdentityCalibrationEmbeddingProducing
{
    private let result: CalibrationEmbeddingResult
    private(set) var callCount = 0

    init(_ result: CalibrationEmbeddingResult) {
        self.result = result
    }

    func embedding(for frame: CameraFrame) async throws -> FaceEmbedding? {
        _ = frame
        callCount += 1
        switch result {
        case .noUsableFace:
            return nil
        case let .success(embedding):
            return embedding
        case .failure:
            throw MarkerError.marker
        }
    }
}

private final class IdentityFactoryDiagnosticRecorder: @unchecked Sendable {
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

private actor RecordingCalibrationFrameSource: IdentityCalibrationFrameSource {
    private var running = false
    private var pending: CheckedContinuation<CameraFrame, Error>?
    private var nextFrameStarted = AsyncStream<Void>.makeStream(
        of: Void.self,
        bufferingPolicy: .bufferingNewest(16)
    )
    private(set) var startCallCount = 0
    private(set) var nextFrameCallCount = 0

    func start() async throws {
        running = true
        startCallCount += 1
    }

    func stop() async {
        running = false
        pending?.resume(throwing: CancellationError())
        pending = nil
    }

    func nextFrame() async throws -> CameraFrame {
        try Task.checkCancellation()
        guard running, pending == nil else {
            throw IdentityCalibrationError.failed
        }
        nextFrameCallCount += 1
        nextFrameStarted.continuation.yield(())

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                if Task.isCancelled {
                    pending = nil
                    continuation.resume(throwing: CancellationError())
                }
            }
        }, onCancel: {
            Task { await self.cancelPending() }
        })
    }

    func waitForNextFrameRequest() async {
        var iterator = nextFrameStarted.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func send(_ frame: CameraFrame) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: frame)
    }

    private func cancelPending() {
        pending?.resume(throwing: CancellationError())
        pending = nil
    }
}

private actor DelayedStartCalibrationFrameSource: IdentityCalibrationFrameSource {
    private var startContinuations: [CheckedContinuation<Void, Error>] = []
    private var startCallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() async throws {
        startCallCount += 1
        let ready = startCallWaiters.filter { startCallCount >= $0.0 }
        startCallWaiters.removeAll { startCallCount >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        try await withCheckedThrowingContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func stop() async {
        stopCallCount += 1
    }

    func nextFrame() async throws -> CameraFrame {
        throw IdentityCalibrationError.failed
    }

    func waitForStartCall(count: Int) async {
        if startCallCount >= count { return }
        await withCheckedContinuation {
            startCallWaiters.append((count, $0))
        }
    }

    func releaseStarts() {
        let continuations = startContinuations
        startContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor DelayedStopCalibrationFrameSource: IdentityCalibrationFrameSource {
    private var delayedStop = true
    private var pendingStop: CheckedContinuation<Void, Never>?
    private var stopCallWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() async throws {
        startCallCount += 1
    }

    func stop() async {
        stopCallCount += 1
        let waiters = stopCallWaiters
        stopCallWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        guard delayedStop else { return }
        delayedStop = false
        await withCheckedContinuation { continuation in
            pendingStop = continuation
        }
    }

    func nextFrame() async throws -> CameraFrame {
        throw IdentityCalibrationError.failed
    }

    func waitForStopCall() async {
        if stopCallCount > 0 { return }
        await withCheckedContinuation {
            stopCallWaiters.append($0)
        }
    }

    func releaseStop() {
        pendingStop?.resume()
        pendingStop = nil
    }
}

private actor PreviewingCalibrationFrameSource: IdentityCalibrationFrameSource {
    private var streamPair = AsyncStream<CameraFrame>.makeStream(
        of: CameraFrame.self,
        bufferingPolicy: .bufferingNewest(1)
    )
    private var running = false

    func start() async throws {
        streamPair = AsyncStream<CameraFrame>.makeStream(
            of: CameraFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        running = true
    }

    func stop() async {
        running = false
        streamPair.continuation.finish()
    }

    func nextFrame() async throws -> CameraFrame {
        guard running else { throw IdentityCalibrationError.failed }
        throw IdentityCalibrationError.failed
    }

    func previewFrames() async -> AsyncStream<CameraFrame> {
        streamPair.stream
    }

    func sendPreview(_ frame: CameraFrame) {
        _ = streamPair.continuation.yield(frame)
    }
}

private actor TerminatingPreviewFrameSource: IdentityCalibrationFrameSource {
    private var streamPair = AsyncStream<CameraFrame>.makeStream(
        of: CameraFrame.self,
        bufferingPolicy: .bufferingNewest(1)
    )
    private var running = false
    private var previewConsumerStarted = AsyncStream<Void>.makeStream(
        of: Void.self,
        bufferingPolicy: .bufferingNewest(1)
    )
    private var previewConsumerEnded = AsyncStream<Void>.makeStream(
        of: Void.self,
        bufferingPolicy: .bufferingNewest(1)
    )
    private(set) var previewConsumerTerminated = false

    func start() async throws {
        streamPair = AsyncStream<CameraFrame>.makeStream(
            of: CameraFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        streamPair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.markPreviewConsumerTerminated()
            }
        }
        running = true
        previewConsumerTerminated = false
    }

    func stop() async {
        running = false
        streamPair.continuation.finish()
    }

    func nextFrame() async throws -> CameraFrame {
        guard running else { throw IdentityCalibrationError.failed }
        throw IdentityCalibrationError.failed
    }

    func previewFrames() async -> AsyncStream<CameraFrame> {
        previewConsumerStarted.continuation.yield(())
        return streamPair.stream
    }

    func waitForPreviewConsumer() async {
        var iterator = previewConsumerStarted.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitForPreviewConsumerTermination() async {
        if previewConsumerTerminated { return }
        var iterator = previewConsumerEnded.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    private func markPreviewConsumerTerminated() {
        guard !previewConsumerTerminated else { return }
        previewConsumerTerminated = true
        previewConsumerEnded.continuation.yield(())
    }
}

private actor BufferedCameraAdapter: IdentityCalibrationCameraAdapter {
    private var streamPair = AsyncStream<CameraFrame>.makeStream(
        of: CameraFrame.self,
        bufferingPolicy: .bufferingNewest(1)
    )

    func start() async throws -> AsyncStream<CameraFrame> {
        streamPair = AsyncStream<CameraFrame>.makeStream(
            of: CameraFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        return streamPair.stream
    }

    func stop() async {
        streamPair.continuation.finish()
    }

    func send(_ frame: CameraFrame) {
        _ = streamPair.continuation.yield(frame)
    }
}

private actor RestartableBufferedCameraAdapter: IdentityCalibrationCameraAdapter {
    private var streamPair = AsyncStream<CameraFrame>.makeStream(
        of: CameraFrame.self,
        bufferingPolicy: .bufferingNewest(1)
    )

    func start() async throws -> AsyncStream<CameraFrame> {
        streamPair = AsyncStream<CameraFrame>.makeStream(
            of: CameraFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        return streamPair.stream
    }

    func stop() async {
        streamPair.continuation.finish()
    }

    func send(_ frame: CameraFrame) {
        _ = streamPair.continuation.yield(frame)
    }
}

private actor RecordingCalibrationStore: IdentityCalibrationStore {
    private var samples: [StoredFaceEmbeddingSample] = []
    private(set) var saveCallCount = 0
    private(set) var sFaceSamplesCallCount = 0
    private(set) var savedMemberIDs: [MemberID] = []
    private(set) var savedDates: [Date] = []
    private(set) var deletedMemberIDs: [MemberID] = []

    func seed(_ samples: [StoredFaceEmbeddingSample]) {
        self.samples = samples
    }

    func save(
        memberID: MemberID,
        embedding: FaceEmbedding,
        createdAt: Date
    ) async throws {
        saveCallCount += 1
        savedMemberIDs.append(memberID)
        savedDates.append(createdAt)
        samples.append(StoredFaceEmbeddingSample(memberID: memberID, embedding: embedding))
    }

    func sFaceSamples() async throws -> [StoredFaceEmbeddingSample] {
        sFaceSamplesCallCount += 1
        return samples
    }

    func sFaceSamples(for memberID: MemberID) async throws -> [StoredFaceEmbeddingSample] {
        samples.filter { $0.memberID == memberID }
    }

    func deleteRecords(for memberID: MemberID) async throws {
        deletedMemberIDs.append(memberID)
        samples.removeAll { $0.memberID == memberID }
    }
}

private actor FailingCalibrationStore: IdentityCalibrationStore {
    func save(
        memberID: MemberID,
        embedding: FaceEmbedding,
        createdAt: Date
    ) async throws {
        _ = memberID
        _ = embedding
        _ = createdAt
        throw MarkerError.marker
    }

    func sFaceSamples() async throws -> [StoredFaceEmbeddingSample] {
        throw MarkerError.marker
    }

    func sFaceSamples(for memberID: MemberID) async throws -> [StoredFaceEmbeddingSample] {
        _ = memberID
        throw MarkerError.marker
    }

    func deleteRecords(for memberID: MemberID) async throws {
        _ = memberID
        throw MarkerError.marker
    }
}

private actor CommitOnCancellationCalibrationStore: IdentityCalibrationStore {
    private var saveStarted = AsyncStream<Void>.makeStream(
        of: Void.self,
        bufferingPolicy: .bufferingNewest(1)
    )
    private(set) var committed = false

    func save(
        memberID: MemberID,
        embedding: FaceEmbedding,
        createdAt: Date
    ) async throws {
        _ = memberID
        _ = embedding
        _ = createdAt
        saveStarted.continuation.yield(())
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pendingSave = continuation
                if Task.isCancelled {
                    pendingSave = nil
                    committed = true
                    continuation.resume(returning: ())
                }
            }
        }, onCancel: {
            Task { await self.commitAfterCancellation() }
        })
        committed = true
    }

    func sFaceSamples() async throws -> [StoredFaceEmbeddingSample] { [] }

    func sFaceSamples(for memberID: MemberID) async throws -> [StoredFaceEmbeddingSample] {
        _ = memberID
        return []
    }

    func deleteRecords(for memberID: MemberID) async throws {
        _ = memberID
    }

    func waitForSaveStart() async {
        var iterator = saveStarted.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    private var pendingSave: CheckedContinuation<Void, Error>?

    private func commitAfterCancellation() {
        committed = true
        pendingSave?.resume(returning: ())
        pendingSave = nil
    }
}

private enum MarkerError: Error {
    case marker
}
