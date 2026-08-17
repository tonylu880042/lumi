import Foundation
import LumiDomain
@testable import LumiInfrastructure
import Testing

@Suite("SFace enrollment sample recorder")
struct SFaceEnrollmentSampleRecorderTests {
    @Test("no usable face returns nil result and does not save")
    func noUsableFaceDoesNotSave() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
        let pipeline = RecordingEmbeddingPipeline(.noUsableFace)
        let recorder = SFaceEnrollmentSampleRecorder(
            pipeline: pipeline,
            store: store
        )
        let memberID = try MemberID(rawValue: "member-001")

        let result = try await recorder.record(
            frame: makeFrame(),
            for: memberID,
            at: Date(timeIntervalSince1970: 100)
        )

        #expect(result == .noUsableFace)
        #expect(try await store.sFaceSamples().isEmpty)
        #expect(await pipeline.callCount == 1)
    }

    @Test("stores exact embeddings and dates with cumulative member isolation")
    func storesExactSamplesAndSeparatesMembers() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
        let firstMember = try MemberID(rawValue: "member-001")
        let secondMember = try MemberID(rawValue: "member-002")
        let firstEmbedding = try makeEmbedding(axis: 0)
        let secondEmbedding = try makeEmbedding(axis: 1)
        let thirdEmbedding = try makeEmbedding(axis: 2)
        let pipeline = RecordingEmbeddingPipeline(.successes([
            firstEmbedding,
            secondEmbedding,
            thirdEmbedding
        ]))
        let recorder = SFaceEnrollmentSampleRecorder(
            pipeline: pipeline,
            store: store
        )

        #expect(try await recorder.record(
            frame: makeFrame(),
            for: firstMember,
            at: Date(timeIntervalSince1970: 100)
        ) == .stored)
        #expect(try await recorder.record(
            frame: makeFrame(),
            for: firstMember,
            at: Date(timeIntervalSince1970: 200)
        ) == .stored)
        #expect(try await recorder.record(
            frame: makeFrame(),
            for: secondMember,
            at: Date(timeIntervalSince1970: 150)
        ) == .stored)

        let allSamples = try await store.sFaceSamples()
        #expect(allSamples.count == 3)
        #expect(allSamples.filter { $0.memberID == firstMember }.map(\.embedding) == [
            firstEmbedding,
            secondEmbedding
        ])
        #expect(allSamples.filter { $0.memberID == secondMember }.map(\.embedding) == [
            thirdEmbedding
        ])

        let firstRecords = try await store.records(for: firstMember)
        #expect(firstRecords.map(\.createdAt.timeIntervalSince1970) == [100, 200])
        let decoded = try firstRecords.map {
            try SFaceEmbeddingRecordCodec.decode(
                $0.embedding,
                modelVersion: $0.modelVersion
            )
        }
        #expect(decoded == [firstEmbedding, secondEmbedding])
    }

    @Test("pipeline failure is redacted and does not produce a stored result")
    func pipelineFailureIsRedacted() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteFaceEmbeddingStore(databaseURL: databaseURL)
        let pipeline = RecordingEmbeddingPipeline(.failure)
        let recorder = SFaceEnrollmentSampleRecorder(
            pipeline: pipeline,
            store: store
        )

        do {
            _ = try await recorder.record(
                frame: makeFrame(),
                for: try MemberID(rawValue: "member-001"),
                at: Date(timeIntervalSince1970: 100)
            )
            Issue.record("expected recorder failure")
        } catch let error as SFaceEnrollmentSampleRecorderError {
            #expect(error == .failed)
            #expect(String(describing: error) == "SFace enrollment sample recorder failed.")
            #expect(!String(reflecting: error).contains("pipeline"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(try await store.sFaceSamples().isEmpty)
    }

    @Test("store failure is redacted and does not report success")
    func storeFailureIsRedacted() async throws {
        let pipeline = RecordingEmbeddingPipeline(.successes([
            try makeEmbedding(axis: 0)
        ]))
        let store = RecordingEnrollmentStore(.failure)
        let recorder = makeRecorder(pipeline: pipeline, store: store)

        await #expect(throws: SFaceEnrollmentSampleRecorderError.failed) {
            _ = try await recorder.record(
                frame: makeFrame(),
                for: try MemberID(rawValue: "member-001"),
                at: Date(timeIntervalSince1970: 100)
            )
        }
        #expect(await store.callCount == 1)
    }

    @Test("non-finite dates fail before pipeline and store")
    func rejectsNonFiniteDateBeforeDependencies() async throws {
        let pipeline = RecordingEmbeddingPipeline(.successes([
            try makeEmbedding(axis: 0)
        ]))
        let store = RecordingEnrollmentStore(.success)
        let recorder = makeRecorder(pipeline: pipeline, store: store)

        await #expect(throws: SFaceEnrollmentSampleRecorderError.failed) {
            _ = try await recorder.record(
                frame: makeFrame(),
                for: try MemberID(rawValue: "member-001"),
                at: Date(timeIntervalSinceReferenceDate: .infinity)
            )
        }
        #expect(await pipeline.callCount == 0)
        #expect(await store.callCount == 0)
    }

    @Test("pre-cancellation skips pipeline and store")
    func preCancellationSkipsDependencies() async throws {
        let pipeline = RecordingEmbeddingPipeline(.successes([
            try makeEmbedding(axis: 0)
        ]))
        let store = RecordingEnrollmentStore(.success)
        let recorder = makeRecorder(pipeline: pipeline, store: store)
        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            _ = try await recorder.record(
                frame: makeFrame(),
                for: try MemberID(rawValue: "member-001"),
                at: Date(timeIntervalSince1970: 100)
            )
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await pipeline.callCount == 0)
        #expect(await store.callCount == 0)
    }

    @Test("store cancellation is preserved without a success result")
    func suspendedStoreCancellationIsPreserved() async throws {
        let pipeline = RecordingEmbeddingPipeline(.successes([
            try makeEmbedding(axis: 0)
        ]))
        let store = SuspendedEnrollmentStore()
        let recorder = makeRecorder(pipeline: pipeline, store: store)
        let task = Task {
            _ = try await recorder.record(
                frame: makeFrame(),
                for: try MemberID(rawValue: "member-001"),
                at: Date(timeIntervalSince1970: 100)
            )
        }

        await store.waitForStart()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await store.callCount == 1)
    }

    @Test("committed store cancellation returns stored after save succeeds")
    func committedStoreCancellationReturnsStored() async throws {
        let pipeline = RecordingEmbeddingPipeline(.successes([
            try makeEmbedding(axis: 0)
        ]))
        let store = CommitOnCancellationEnrollmentStore()
        let recorder = makeRecorder(pipeline: pipeline, store: store)
        let task = Task {
            try await recorder.record(
                frame: makeFrame(),
                for: try MemberID(rawValue: "member-001"),
                at: Date(timeIntervalSince1970: 100)
            )
        }

        await store.waitForStart()
        task.cancel()

        let result = try await task.value
        #expect(result == .stored)
        #expect(await store.callCount == 1)
        #expect(await store.committed)
    }

    @Test("recorder, result, and error are Sendable values")
    func valuesAreSendable() throws {
        let recorder = makeRecorder(
            pipeline: RecordingEmbeddingPipeline(.noUsableFace),
            store: RecordingEnrollmentStore(.success)
        )

        acceptsSendable(recorder)
        acceptsSendable(SFaceEnrollmentSampleResult.noUsableFace)
        acceptsSendable(SFaceEnrollmentSampleResult.stored)
        acceptsSendable(SFaceEnrollmentSampleRecorderError.failed)
    }

    private func makeRecorder(
        pipeline: any SFaceFrameEmbeddingProducing,
        store: any SFaceEnrollmentStoreWriting
    ) -> SFaceEnrollmentSampleRecorder {
        SFaceEnrollmentSampleRecorder(pipeline: pipeline, store: store)
    }

    private func makeFrame() throws -> CameraFrame {
        try CameraFrame(
            bytes: Data([0, 0, 0, 255]),
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

    private func temporaryDatabaseURL() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-enrollment-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }
}

private enum PipelineOutcome: Sendable {
    case noUsableFace
    case successes([FaceEmbedding])
    case failure
}

private actor RecordingEmbeddingPipeline: SFaceFrameEmbeddingProducing {
    private let outcome: PipelineOutcome
    private(set) var callCount = 0
    private var successIndex = 0

    init(_ outcome: PipelineOutcome) {
        self.outcome = outcome
    }

    func embedding(for frame: CameraFrame) async throws -> FaceEmbedding? {
        _ = frame
        callCount += 1
        switch outcome {
        case .noUsableFace:
            return nil
        case .successes(let embeddings):
            guard successIndex < embeddings.count else {
                throw RecorderFakeError.failed
            }
            defer { successIndex += 1 }
            return embeddings[successIndex]
        case .failure:
            throw RecorderFakeError.failed
        }
    }
}

private enum StoreOutcome: Sendable {
    case success
    case failure
}

private actor RecordingEnrollmentStore: SFaceEnrollmentStoreWriting {
    private let outcome: StoreOutcome
    private(set) var callCount = 0

    init(_ outcome: StoreOutcome) {
        self.outcome = outcome
    }

    func save(
        memberID: MemberID,
        embedding: FaceEmbedding,
        createdAt: Date
    ) async throws {
        _ = (memberID, embedding, createdAt)
        callCount += 1
        if case .failure = outcome {
            throw RecorderFakeError.failed
        }
    }
}

private actor SuspendedEnrollmentStore: SFaceEnrollmentStoreWriting {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false
    private var saveContinuation: CheckedContinuation<Void, Error>?
    private(set) var callCount = 0

    func save(
        memberID: MemberID,
        embedding: FaceEmbedding,
        createdAt: Date
    ) async throws {
        _ = (memberID, embedding, createdAt)
        callCount += 1
        started = true
        startWaiter?.resume()
        startWaiter = nil

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if cancellationRequested {
                    continuation.resume(throwing: CancellationError())
                } else {
                    saveContinuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelSave() }
        })
    }

    func waitForStart() async {
        if started { return }

        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    private func cancelSave() {
        cancellationRequested = true
        saveContinuation?.resume(throwing: CancellationError())
        saveContinuation = nil
    }
}

private actor CommitOnCancellationEnrollmentStore: SFaceEnrollmentStoreWriting {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false
    private var saveContinuation: CheckedContinuation<Void, Error>?
    private(set) var callCount = 0
    private(set) var committed = false

    func save(
        memberID: MemberID,
        embedding: FaceEmbedding,
        createdAt: Date
    ) async throws {
        _ = (memberID, embedding, createdAt)
        callCount += 1
        started = true
        startWaiter?.resume()
        startWaiter = nil

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if cancellationRequested {
                    committed = true
                    continuation.resume()
                } else {
                    saveContinuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.commitAfterCancellation() }
        })
        committed = true
    }

    func waitForStart() async {
        if started { return }

        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    private func commitAfterCancellation() {
        cancellationRequested = true
        committed = true
        saveContinuation?.resume()
        saveContinuation = nil
    }
}

private enum RecorderFakeError: Error, Sendable {
    case failed
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
