import Foundation
import LumiDomain
@testable import LumiApplication
import Testing

@Suite("Identity calibration application port")
struct IdentityCalibrationPortTests {
    @Test("evidence keeps temporary member candidates and calibration-only scores")
    func evidenceKeepsCandidatesAndScores() throws {
        let firstMember = try MemberID(rawValue: "temporary-a")
        let secondMember = try MemberID(rawValue: "temporary-b")
        let evidence = IdentityCalibrationEvidence(
            gallerySampleCount: 4,
            top1: IdentityCalibrationCandidate(
                memberID: firstMember,
                cosineSimilarity: 0.91
            ),
            top2: IdentityCalibrationCandidate(
                memberID: secondMember,
                cosineSimilarity: 0.73
            )
        )

        #expect(evidence.gallerySampleCount == 4)
        #expect(evidence.top1?.memberID == firstMember)
        #expect(evidence.top1?.cosineSimilarity == 0.91)
        #expect(evidence.top2?.memberID == secondMember)
        #expect(evidence.top2?.cosineSimilarity == 0.73)
        #expect(abs((evidence.margin ?? 0) - 0.18) < 0.000_001)
    }

    @Test("port values and errors are Sendable and Equatable")
    func valuesAreSendable() throws {
        let memberID = try MemberID(rawValue: "temporary")
        let candidate = IdentityCalibrationCandidate(
            memberID: memberID,
            cosineSimilarity: 0.5
        )
        let evidence = IdentityCalibrationEvidence(
            gallerySampleCount: 1,
            top1: candidate,
            top2: nil
        )

        acceptsSendable(IdentityCalibrationCaptureResult.noUsableFace)
        acceptsSendable(IdentityCalibrationCaptureResult.stored)
        acceptsSendable(IdentityCalibrationReturnResult.noUsableFace)
        acceptsSendable(IdentityCalibrationReturnResult.measured(evidence))
        acceptsSendable(IdentityCalibrationError.failed)
        acceptsSendable(candidate)
        acceptsSendable(evidence)
    }

    @Test("port has explicit lifecycle, capture, count, and scoped reset operations")
    func portContractIsUsable() async throws {
        let port: any IdentityCalibrationPort = RecordingCalibrationPort()
        let memberID = try MemberID(rawValue: "temporary")
        let imageURL = URL(fileURLWithPath: "/tmp/temporary-calibration.jpg")

        try await port.startCamera()
        _ = try await port.captureEnrollmentSample(
            for: memberID,
            at: Date(timeIntervalSince1970: 100)
        )
        _ = try await port.captureReturnVisit()
        _ = try await port.captureEnrollmentPhoto(
            for: memberID,
            from: imageURL,
            at: Date(timeIntervalSince1970: 101)
        )
        _ = try await port.captureReturnVisitPhoto(from: imageURL)
        _ = try await port.sampleCount(for: memberID)
        try await port.reset(for: memberID)
        await port.stopCamera()
    }

    @Test("photo payload owns encoded bytes and supports transient Data captures")
    func photoPayloadContractIsUsable() async throws {
        let payload = IdentityCalibrationPhoto(data: Data([0x01, 0x02, 0x03]))
        let port: any IdentityCalibrationPort = RecordingCalibrationPort()
        let memberID = try MemberID(rawValue: "temporary-data-photo")

        #expect(payload.data == Data([0x01, 0x02, 0x03]))
        acceptsSendable(payload)
        _ = try await port.captureEnrollmentPhoto(
            for: memberID,
            from: payload,
            at: Date(timeIntervalSince1970: 102)
        )
        _ = try await port.captureReturnVisitPhoto(from: payload)
    }

    @Test("preview value preserves owned BGRA bytes and frame metadata")
    func previewValuePreservesBGRABytesAndMetadata() throws {
        let preview = IdentityCalibrationPreviewFrame(
            bgraBytes: Data([0x10, 0x20, 0x30, 0xFF, 0x40, 0x50, 0x60, 0xFF]),
            width: 2,
            height: 1,
            bytesPerRow: 8
        )

        #expect(preview.bgraBytes == Data([
            0x10, 0x20, 0x30, 0xFF, 0x40, 0x50, 0x60, 0xFF
        ]))
        #expect(preview.width == 2)
        #expect(preview.height == 1)
        #expect(preview.bytesPerRow == 8)
        acceptsSendable(preview)
    }

    @Test("compatibility preview stream is finished before camera start")
    func compatibilityPreviewStreamFinishesBeforeStart() async throws {
        let port: any IdentityCalibrationPort = RecordingCalibrationPort()

        var iterator = (await port.previewFrames()).makeAsyncIterator()

        #expect(await iterator.next() == nil)
    }

    private func acceptsSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}

private actor RecordingCalibrationPort: IdentityCalibrationPort {
    func startCamera() async throws {}

    func stopCamera() async {}

    func captureEnrollmentSample(
        for memberID: MemberID,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        _ = memberID
        _ = createdAt
        return .noUsableFace
    }

    func captureReturnVisit() async throws -> IdentityCalibrationReturnResult {
        .noUsableFace
    }

    func captureEnrollmentPhoto(
        for memberID: MemberID,
        from imageURL: URL,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        _ = memberID
        _ = imageURL
        _ = createdAt
        return .noUsableFace
    }

    func captureEnrollmentPhoto(
        for memberID: MemberID,
        from photo: IdentityCalibrationPhoto,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        _ = memberID
        _ = photo
        _ = createdAt
        return .noUsableFace
    }

    func captureReturnVisitPhoto(
        from imageURL: URL
    ) async throws -> IdentityCalibrationReturnResult {
        _ = imageURL
        return .noUsableFace
    }

    func captureReturnVisitPhoto(
        from photo: IdentityCalibrationPhoto
    ) async throws -> IdentityCalibrationReturnResult {
        _ = photo
        return .noUsableFace
    }

    func sampleCount(for memberID: MemberID) async throws -> Int {
        _ = memberID
        return 0
    }

    func reset(for memberID: MemberID) async throws {
        _ = memberID
    }
}
