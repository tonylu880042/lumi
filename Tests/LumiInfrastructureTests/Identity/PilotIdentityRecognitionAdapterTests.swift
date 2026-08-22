#if DEBUG

import LumiApplication
import LumiDomain
@testable import LumiInfrastructure
import Testing

@Suite("44B pilot identity recognition adapter")
struct PilotIdentityRecognitionAdapterTests {
    @Test("three fresh measurements map a clear two-of-three decision to known")
    func recognizesClearMember() async throws {
        let tony = try MemberID(rawValue: "tony")
        let ruby = try MemberID(rawValue: "ruby")
        let source = RecordingPilotRecognitionSource(results: [
            .success(try evidence(best: tony, score: 0.85, second: ruby, secondScore: 0.30)),
            .success(try evidence(best: tony, score: 0.76, second: ruby, secondScore: 0.40)),
            .success(try evidence(best: ruby, score: 0.74, second: tony, secondScore: 0.50)),
        ])
        let adapter = PilotIdentityRecognitionAdapter(source: source)

        let result = try await adapter.recognizeCurrentVisitor()

        let confidence = try RecognitionConfidence(value: 0.76)
        #expect(result == .known(memberID: tony, confidence: confidence))
        #expect(await source.startCount == 1)
        #expect(await source.captureCount == 3)
        #expect(await source.stopCount == 1)
    }

    @Test("no usable face remains public unknown after all three fresh measurements")
    func mapsNoFaceToUnknown() async throws {
        let source = RecordingPilotRecognitionSource(results: [
            .success(.noUsableFace),
            .success(.noUsableFace),
            .success(.noUsableFace),
        ])
        let adapter = PilotIdentityRecognitionAdapter(source: source)

        #expect(try await adapter.recognizeCurrentVisitor() == .unknown)
        #expect(await source.captureCount == 3)
        #expect(await source.stopCount == 1)
    }

    @Test("an empty gallery remains public unknown")
    func mapsEmptyGalleryToUnknown() async throws {
        let empty = IdentityCalibrationEvidence(
            gallerySampleCount: 0,
            top1: nil,
            top2: nil
        )
        let source = RecordingPilotRecognitionSource(results: [
            .success(.measured(empty)),
            .success(.measured(empty)),
            .success(.measured(empty)),
        ])
        let adapter = PilotIdentityRecognitionAdapter(source: source)

        #expect(try await adapter.recognizeCurrentVisitor() == .unknown)
        #expect(await source.stopCount == 1)
    }

    @Test("malformed score fails closed and stops the camera")
    func rejectsMalformedEvidence() async throws {
        let tony = try MemberID(rawValue: "tony")
        let ruby = try MemberID(rawValue: "ruby")
        let malformed = IdentityCalibrationEvidence(
            gallerySampleCount: 2,
            top1: IdentityCalibrationCandidate(
                memberID: tony,
                cosineSimilarity: .nan
            ),
            top2: IdentityCalibrationCandidate(
                memberID: ruby,
                cosineSimilarity: 0.2
            )
        )
        let source = RecordingPilotRecognitionSource(results: [
            .success(.measured(malformed)),
        ])
        let adapter = PilotIdentityRecognitionAdapter(source: source)

        await #expect(throws: PilotIdentityRecognitionError.failed) {
            _ = try await adapter.recognizeCurrentVisitor()
        }
        #expect(await source.stopCount == 1)
    }

    @Test("source failure is redacted and stops the camera")
    func redactsSourceFailure() async {
        let source = RecordingPilotRecognitionSource(results: [
            .failure(PrivatePilotSourceError.secret),
        ])
        let adapter = PilotIdentityRecognitionAdapter(source: source)

        await #expect(throws: PilotIdentityRecognitionError.failed) {
            _ = try await adapter.recognizeCurrentVisitor()
        }
        #expect(await source.stopCount == 1)
        #expect(PilotIdentityRecognitionError.failed.description ==
            "Pilot identity recognition failed.")
        #expect(PilotIdentityRecognitionError.failed.debugDescription ==
            "Pilot identity recognition failed.")
        #expect(PilotIdentityRecognitionError.failed.customMirror.children.isEmpty)
    }

    @Test("cancellation while measuring is preserved and stops the camera")
    func preservesCancellation() async throws {
        let source = SuspendedPilotRecognitionSource()
        let adapter = PilotIdentityRecognitionAdapter(source: source)
        let task = Task { try await adapter.recognizeCurrentVisitor() }
        await source.waitForCapture()

        task.cancel()
        await source.resumeCapture()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await source.stopCount == 1)
    }

    @Test("a second recognition cannot start while the first is suspended")
    func rejectsConcurrentRecognition() async throws {
        let source = SuspendedPilotRecognitionSource()
        let adapter = PilotIdentityRecognitionAdapter(source: source)
        let first = Task { try await adapter.recognizeCurrentVisitor() }
        await source.waitForCapture()

        await #expect(throws: PilotIdentityRecognitionError.operationInProgress) {
            _ = try await adapter.recognizeCurrentVisitor()
        }
        #expect(await source.startCount == 1)

        first.cancel()
        await source.resumeCapture()
        _ = await first.result
    }
}

private actor RecordingPilotRecognitionSource: PilotRecognitionEvidenceSource {
    private var results: [Result<IdentityCalibrationReturnResult, Error>]
    private(set) var startCount = 0
    private(set) var captureCount = 0
    private(set) var stopCount = 0

    init(results: [Result<IdentityCalibrationReturnResult, Error>]) {
        self.results = results
    }

    func startCamera() async throws {
        startCount += 1
    }

    func stopCamera() async {
        stopCount += 1
    }

    func captureReturnVisit() async throws -> IdentityCalibrationReturnResult {
        captureCount += 1
        guard !results.isEmpty else { throw PrivatePilotSourceError.secret }
        return try results.removeFirst().get()
    }
}

private actor SuspendedPilotRecognitionSource: PilotRecognitionEvidenceSource {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var captureContinuation: CheckedContinuation<Void, Never>?
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []

    func startCamera() async throws {
        startCount += 1
    }

    func stopCamera() async {
        stopCount += 1
    }

    func captureReturnVisit() async throws -> IdentityCalibrationReturnResult {
        for waiter in captureWaiters { waiter.resume() }
        captureWaiters.removeAll()
        await withCheckedContinuation { continuation in
            captureContinuation = continuation
        }
        try Task.checkCancellation()
        return .noUsableFace
    }

    func waitForCapture() async {
        if captureContinuation != nil { return }
        await withCheckedContinuation { continuation in
            captureWaiters.append(continuation)
        }
    }

    func resumeCapture() {
        captureContinuation?.resume()
        captureContinuation = nil
    }
}

private enum PrivatePilotSourceError: Error {
    case secret
}

private func evidence(
    best: MemberID,
    score: Double,
    second: MemberID,
    secondScore: Double
) throws -> IdentityCalibrationReturnResult {
    .measured(IdentityCalibrationEvidence(
        gallerySampleCount: 2,
        top1: IdentityCalibrationCandidate(
            memberID: best,
            cosineSimilarity: score
        ),
        top2: IdentityCalibrationCandidate(
            memberID: second,
            cosineSimilarity: secondScore
        )
    ))
}

#endif
