#if DEBUG

import Foundation
import LumiApplication
import LumiDomain
@testable import LumiInfrastructure
import Testing

@Suite("Core ML conversational enrollment")
struct CoreMLConversationalEnrollmentTests {
    @Test("three samples stay in memory until naming completes")
    func samplesStayPendingUntilComplete() async throws {
        let embeddings = try [0, 1, 2].map(makeEmbedding)
        let frameSource = EnrollmentFrameSource(frames: try makeFrames(count: 3))
        let pipeline = EnrollmentEmbeddingPipeline(embeddings: embeddings)
        let store = RecordingConversationalEnrollmentStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: frameSource,
            embeddingPipeline: pipeline,
            store: store,
            visitorEnrollmentStore: store
        )
        let consentedAt = Date(timeIntervalSince1970: 100)
        let completedAt = Date(timeIntervalSince1970: 200)
        let memberID = try MemberID(rawValue: "local-uuid")
        let address = try VoiceMemberAddress(spokenLabel: "Tony")

        let begin = try await service.begin(consentedAt: consentedAt)

        #expect(begin == .samplesCaptured(3))
        #expect(await pipeline.requestCount == 3)
        #expect(await store.commits.isEmpty)
        #expect(await frameSource.startCount == 1)
        #expect(await frameSource.stopCount == 1)

        try await service.complete(
            memberID: memberID,
            address: address,
            completedAt: completedAt
        )

        #expect(await store.commits == [EnrollmentCommit(
            memberID: memberID,
            address: address,
            consentedAt: consentedAt,
            completedAt: completedAt,
            embeddings: embeddings
        )])
    }

    @Test("one unusable frame discards every pending sample")
    func unusableFrameDiscardsPendingSamples() async throws {
        let frameSource = EnrollmentFrameSource(frames: try makeFrames(count: 3))
        let pipeline = EnrollmentEmbeddingPipeline(embeddings: [
            try makeEmbedding(axis: 0), nil, try makeEmbedding(axis: 2)
        ])
        let store = RecordingConversationalEnrollmentStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: frameSource,
            embeddingPipeline: pipeline,
            store: store,
            visitorEnrollmentStore: store
        )

        #expect(
            try await service.begin(consentedAt: Date(timeIntervalSince1970: 100))
                == .noUsableFace
        )
        #expect(await pipeline.requestCount == 2)
        #expect(await store.commits.isEmpty)
        #expect(await frameSource.stopCount == 1)

        await #expect(throws: IdentityCalibrationError.failed) {
            try await service.complete(
                memberID: MemberID(rawValue: "local-none"),
                address: VoiceMemberAddress(spokenLabel: "Tony"),
                completedAt: Date(timeIntervalSince1970: 200)
            )
        }
    }

    @Test("cancel after capture clears memory without a store write")
    func cancelClearsPendingSamples() async throws {
        let frameSource = EnrollmentFrameSource(frames: try makeFrames(count: 3))
        let pipeline = EnrollmentEmbeddingPipeline(
            embeddings: try [0, 1, 2].map(makeEmbedding)
        )
        let store = RecordingConversationalEnrollmentStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: frameSource,
            embeddingPipeline: pipeline,
            store: store,
            visitorEnrollmentStore: store
        )

        _ = try await service.begin(consentedAt: Date(timeIntervalSince1970: 100))
        await service.cancel()

        #expect(await store.commits.isEmpty)
        await #expect(throws: IdentityCalibrationError.failed) {
            try await service.complete(
                memberID: MemberID(rawValue: "local-cancelled"),
                address: VoiceMemberAddress(spokenLabel: "Tony"),
                completedAt: Date(timeIntervalSince1970: 200)
            )
        }
    }

    @Test("stored address lookup returns only the validated spoken label")
    func storedAddressLookupUsesRepository() async throws {
        let memberID = try MemberID(rawValue: "local-address")
        let address = try VoiceMemberAddress(spokenLabel: "Ruby")
        let store = RecordingConversationalEnrollmentStore(addresses: [memberID: address])
        let service = CoreMLIdentityCalibrationService(
            frameSource: EnrollmentFrameSource(frames: []),
            embeddingPipeline: EnrollmentEmbeddingPipeline(embeddings: []),
            store: store,
            visitorEnrollmentStore: store
        )
        let repository: any VoiceMemberAddressRepository = service

        #expect(try await repository.address(for: memberID) == address)
        acceptsSendable(repository)
    }

    @Test("departure monitoring does not interrupt consented enrollment")
    func departureMonitoringAllowsEnrollmentToComplete() async throws {
        let frameSource = SharedCameraEnrollmentFrameSource()
        let pipeline = EnrollmentEmbeddingPipeline(embeddings: [
            nil,
            try makeEmbedding(axis: 0),
            try makeEmbedding(axis: 1),
            try makeEmbedding(axis: 2),
        ])
        let store = RecordingConversationalEnrollmentStore()
        let service = CoreMLIdentityCalibrationService(
            frameSource: frameSource,
            embeddingPipeline: pipeline,
            store: store,
            visitorEnrollmentStore: store
        )
        let monitor = PilotVisitorPresenceMonitor(
            source: service,
            departureAbsenceDuration: .seconds(10),
            clock: FixedPresenceClock()
        )

        let departure = Task {
            try await monitor.waitForDeparture()
        }
        await frameSource.waitForStart()
        await frameSource.waitForFrameRequest(count: 1)

        let begin = Task {
            try await service.begin(
                consentedAt: Date(timeIntervalSince1970: 100)
            )
        }

        for marker in 0..<4 {
            await frameSource.send(try makeFrame(byte: UInt8(marker)))
            await frameSource.waitForFrameRequest(count: marker + 2)
        }

        #expect(try await begin.value == .samplesCaptured(3))
        try await service.complete(
            memberID: MemberID(rawValue: "local-uuid"),
            address: VoiceMemberAddress(spokenLabel: "Tony"),
            completedAt: Date(timeIntervalSince1970: 200)
        )
        #expect(await store.commits.count == 1)

        await monitor.stop()
        await #expect(throws: CancellationError.self) {
            try await departure.value
        }
    }
}

private struct EnrollmentCommit: Equatable, Sendable {
    let memberID: MemberID
    let address: VoiceMemberAddress
    let consentedAt: Date
    let completedAt: Date
    let embeddings: [FaceEmbedding]
}

private actor RecordingConversationalEnrollmentStore:
    IdentityCalibrationStore,
    VisitorEnrollmentStore
{
    private let addresses: [MemberID: VoiceMemberAddress]
    private(set) var commits: [EnrollmentCommit] = []

    init(addresses: [MemberID: VoiceMemberAddress] = [:]) {
        self.addresses = addresses
    }

    func save(
        memberID: MemberID,
        embedding: FaceEmbedding,
        createdAt: Date
    ) async throws {}

    func sFaceSamples() async throws -> [StoredFaceEmbeddingSample] { [] }

    func sFaceSamples(
        for memberID: MemberID
    ) async throws -> [StoredFaceEmbeddingSample] { [] }

    func deleteRecords(for memberID: MemberID) async throws {}

    func commitVisitorEnrollment(
        memberID: MemberID,
        address: VoiceMemberAddress,
        consentedAt: Date,
        completedAt: Date,
        embeddings: [FaceEmbedding]
    ) async throws {
        commits.append(EnrollmentCommit(
            memberID: memberID,
            address: address,
            consentedAt: consentedAt,
            completedAt: completedAt,
            embeddings: embeddings
        ))
    }

    func address(for memberID: MemberID) async throws -> VoiceMemberAddress? {
        addresses[memberID]
    }
}

private actor EnrollmentFrameSource: IdentityCalibrationFrameSource {
    private var frames: [CameraFrame]
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(frames: [CameraFrame]) {
        self.frames = frames
    }

    func start() async throws { startCount += 1 }
    func stop() async { stopCount += 1 }

    func nextFrame() async throws -> CameraFrame {
        guard !frames.isEmpty else { throw IdentityCalibrationError.failed }
        return frames.removeFirst()
    }
}

private actor SharedCameraEnrollmentFrameSource: IdentityCalibrationFrameSource {
    private var running = false
    private var pendingFrames: [CheckedContinuation<CameraFrame, Error>] = []
    private var frameRequestCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var frameRequestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func start() async throws {
        guard !running else { throw IdentityCalibrationError.failed }
        running = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func stop() async {
        running = false
        let continuations = pendingFrames
        pendingFrames.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }

    func nextFrame() async throws -> CameraFrame {
        try Task.checkCancellation()
        guard running else { throw IdentityCalibrationError.failed }
        frameRequestCount += 1
        let ready = frameRequestWaiters.filter {
            frameRequestCount >= $0.0
        }
        frameRequestWaiters.removeAll { frameRequestCount >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        return try await withCheckedThrowingContinuation {
            pendingFrames.append($0)
        }
    }

    func waitForStart() async {
        if running { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForFrameRequest(count: Int) async {
        if frameRequestCount >= count { return }
        await withCheckedContinuation {
            frameRequestWaiters.append((count, $0))
        }
    }

    func send(_ frame: CameraFrame) {
        guard !pendingFrames.isEmpty else { return }
        pendingFrames.removeFirst().resume(returning: frame)
    }
}

private struct FixedPresenceClock: PilotVisitorPresenceClock {
    func now() -> Duration { .zero }
}

private actor EnrollmentEmbeddingPipeline: IdentityCalibrationEmbeddingProducing {
    private var embeddings: [FaceEmbedding?]
    private(set) var requestCount = 0

    init(embeddings: [FaceEmbedding?]) {
        self.embeddings = embeddings
    }

    func embedding(for frame: CameraFrame) async throws -> FaceEmbedding? {
        requestCount += 1
        guard !embeddings.isEmpty else { throw IdentityCalibrationError.failed }
        return embeddings.removeFirst()
    }
}

private func makeFrames(count: Int) throws -> [CameraFrame] {
    try (0..<count).map { marker in
        try CameraFrame(
            bytes: Data([UInt8(marker), 0, 0, 255]),
            width: 1,
            height: 1,
            bytesPerRow: 4,
            orientation: .upright
        )
    }
}

private func makeFrame(byte: UInt8) throws -> CameraFrame {
    try CameraFrame(
        bytes: Data([byte, 0, 0, 255]),
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

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}

#endif
