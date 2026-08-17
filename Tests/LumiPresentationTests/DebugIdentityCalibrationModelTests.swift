#if DEBUG

import Foundation
import LumiApplication
import LumiDomain
import Testing
@testable import LumiPresentation

@Suite("DEBUG identity calibration presentation model")
@MainActor
struct DebugIdentityCalibrationModelTests {
    @Test("starts stopped and exposes only presentation-owned values")
    func startsStoppedAndIsSendable() throws {
        let model = DebugIdentityCalibrationModel(
            port: RecordingIdentityCalibrationPort()
        )

        #expect(model.state == .stopped)
        #expect(model.memberIDInput.isEmpty)
        #expect(model.selectedMemberID == nil)
        #expect(model.selectedSampleCount == 0)
        #expect(model.scoreEvidence == nil)
        #expect(model.statusMessage == nil)
        acceptsSendable(model.state)
        acceptsSendable(model.scoreEvidence)
    }

    @Test("start maps lifecycle to ready and generic failures to fixed copy")
    func startLifecycleAndFailureCopy() async throws {
        let port = RecordingIdentityCalibrationPort()
        let model = DebugIdentityCalibrationModel(port: port)

        await model.startCamera()

        #expect(model.state == .ready)
        #expect(await port.startCallCount == 1)

        let failingPort = RecordingIdentityCalibrationPort()
        await failingPort.setStartFailure(MarkerError.marker)
        let failingModel = DebugIdentityCalibrationModel(port: failingPort)

        await failingModel.startCamera()

        #expect(failingModel.state == .error(
            message: DebugIdentityCalibrationModel.genericFailureMessage
        ))
        #expect(String(describing: failingModel.state).contains("marker") == false)
    }

    @Test("stopping while start is suspended stops the port after it becomes ready")
    func stopDuringSuspendedStartStopsAfterLoad() async throws {
        let port = RecordingIdentityCalibrationPort()
        await port.setStartSuspended(true)
        let model = DebugIdentityCalibrationModel(port: port)

        let start = Task { @MainActor in
            await model.startCamera()
        }
        await port.waitForStart()
        #expect(model.state == .starting)

        await model.stopCamera()
        #expect(model.state == .stopped)
        #expect(await port.stopCallCount == 1)

        await port.releaseStart()
        await start.value

        #expect(model.state == .stopped)
        #expect(await port.stopCallCount == 2)
    }

    @Test("empty member ID stays ready with validation copy and does not query")
    func emptyMemberIDDoesNotQuery() async throws {
        let port = RecordingIdentityCalibrationPort()
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()

        model.memberIDInput = ""
        await model.selectTemporaryMember()

        #expect(model.state == .ready)
        #expect(model.statusMessage == DebugIdentityCalibrationModel.invalidMemberIDMessage)
        #expect(await port.sampleCountCalls.isEmpty)
    }

    @Test("selecting and switching temporary IDs loads counts without resetting score evidence")
    func selectingAndSwitchingTemporaryIDs() async throws {
        let port = RecordingIdentityCalibrationPort()
        let memberA = try MemberID(rawValue: "temporary-a")
        let memberB = try MemberID(rawValue: "temporary-b")
        await port.seedCount(2, for: memberA)
        await port.seedCount(4, for: memberB)
        await port.setReturnResult(.success(.measured(IdentityCalibrationEvidence(
            gallerySampleCount: 6,
            top1: IdentityCalibrationCandidate(
                memberID: memberA,
                cosineSimilarity: 0.91
            ),
            top2: IdentityCalibrationCandidate(
                memberID: memberB,
                cosineSimilarity: 0.73
            )
        ))))
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()

        await model.captureReturnVisit()
        let originalEvidence = model.scoreEvidence

        model.memberIDInput = memberA.rawValue
        await model.selectTemporaryMember()
        #expect(model.selectedMemberID == memberA.rawValue)
        #expect(model.selectedSampleCount == 2)
        #expect(model.scoreEvidence == originalEvidence)

        model.memberIDInput = memberB.rawValue
        await model.selectTemporaryMember()
        #expect(model.selectedMemberID == memberB.rawValue)
        #expect(model.selectedSampleCount == 4)
        #expect(await port.sampleCountCalls == [memberA, memberB])
        #expect(model.scoreEvidence == originalEvidence)

        await model.captureEnrollment()
        #expect(model.selectedSampleCount == 5)
        #expect(model.scoreEvidence == nil)
    }

    @Test("enrollment increments selected count locally without a post-save count query")
    func enrollmentIncrementsLocally() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-a")
        await port.seedCount(2, for: member)
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()
        model.memberIDInput = member.rawValue
        await model.selectTemporaryMember()

        await model.captureEnrollment()

        #expect(model.state == .ready)
        #expect(model.selectedSampleCount == 3)
        #expect(model.statusMessage == nil)
        #expect(await port.enrollmentMemberIDs == [member])
        #expect(await port.sampleCountCalls == [member])
    }

    @Test("no usable enrollment face retains count and reports no stored sample")
    func noUsableEnrollmentFaceRetainsCount() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-a")
        await port.seedCount(2, for: member)
        await port.setEnrollmentResult(.success(.noUsableFace))
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()
        model.memberIDInput = member.rawValue
        await model.selectTemporaryMember()

        await model.captureEnrollment()

        #expect(model.state == .ready)
        #expect(model.selectedSampleCount == 2)
        #expect(model.statusMessage == DebugIdentityCalibrationModel.noSampleStoredMessage)
        #expect(await port.enrollmentMemberIDs == [member])
    }

    @Test("photo enrollment from stopped forwards the selected ID and URL")
    func photoEnrollmentFromStoppedForwardsSelection() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-photo")
        let imageURL = URL(fileURLWithPath: "/tmp/photo-enrollment.png")
        await port.seedCount(2, for: member)
        let model = DebugIdentityCalibrationModel(port: port)
        model.memberIDInput = member.rawValue
        await model.selectTemporaryMember()

        await model.captureEnrollmentPhoto(from: imageURL)

        #expect(model.state == .stopped)
        #expect(model.selectedSampleCount == 3)
        #expect(model.statusMessage == nil)
        #expect(await port.photoEnrollmentMemberIDs == [member])
        #expect(await port.photoEnrollmentURLs == [imageURL])
        #expect(await port.photoEnrollmentDates.count == 1)
        #expect(await port.sampleCountCalls == [member])
    }

    @Test("photo enrollment no-face preserves count and restores ready")
    func photoEnrollmentNoFacePreservesReadyState() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-photo")
        await port.seedCount(2, for: member)
        await port.setPhotoEnrollmentResult(.success(.noUsableFace))
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()
        model.memberIDInput = member.rawValue
        await model.selectTemporaryMember()

        await model.captureEnrollmentPhoto(
            from: URL(fileURLWithPath: "/tmp/no-face.heic")
        )

        #expect(model.state == .ready)
        #expect(model.selectedSampleCount == 2)
        #expect(model.statusMessage == DebugIdentityCalibrationModel.noSampleStoredMessage)
    }

    @Test("photo enrollment generic failure restores ready with fixed copy")
    func photoEnrollmentGenericFailureRestoresReady() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-photo")
        await port.seedCount(2, for: member)
        await port.setPhotoEnrollmentResult(.failure(MarkerError.marker))
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()
        model.memberIDInput = member.rawValue
        await model.selectTemporaryMember()

        await model.captureEnrollmentPhoto(
            from: URL(fileURLWithPath: "/tmp/failure.jpg")
        )

        #expect(model.state == .ready)
        #expect(model.selectedSampleCount == 2)
        #expect(model.statusMessage == DebugIdentityCalibrationModel.genericFailureMessage)
    }

    @Test("photo return from stopped maps the full gallery without selecting a member")
    func photoReturnFromStoppedMapsGallery() async throws {
        let port = RecordingIdentityCalibrationPort()
        let memberA = try MemberID(rawValue: "temporary-photo-a")
        let memberB = try MemberID(rawValue: "temporary-photo-b")
        await port.setPhotoReturnResult(.success(.measured(IdentityCalibrationEvidence(
            gallerySampleCount: 2,
            top1: IdentityCalibrationCandidate(
                memberID: memberA,
                cosineSimilarity: 0.92
            ),
            top2: IdentityCalibrationCandidate(
                memberID: memberB,
                cosineSimilarity: 0.77
            )
        ))))
        let model = DebugIdentityCalibrationModel(port: port)
        let imageURL = URL(fileURLWithPath: "/tmp/photo-return.jpg")

        await model.captureReturnVisitPhoto(from: imageURL)

        #expect(model.state == .stopped)
        #expect(model.selectedMemberID == nil)
        #expect(model.scoreEvidence?.gallerySampleCount == 2)
        #expect(model.scoreEvidence?.top1?.memberID == memberA.rawValue)
        #expect(model.scoreEvidence?.top2?.memberID == memberB.rawValue)
        #expect(abs((model.scoreEvidence?.margin ?? 0) - 0.15) < 0.000_001)
        #expect(await port.photoReturnURLs == [imageURL])
        #expect(await port.returnCallCount == 0)
    }

    @Test("photo return clears old evidence while waiting and maps measured result")
    func photoReturnClearsEvidenceBeforeWork() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-photo")
        await port.setReturnResult(.success(.measured(IdentityCalibrationEvidence(
            gallerySampleCount: 1,
            top1: IdentityCalibrationCandidate(
                memberID: member,
                cosineSimilarity: 0.88
            ),
            top2: nil
        ))))
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()
        await model.captureReturnVisit()
        #expect(model.scoreEvidence != nil)

        await port.setPhotoReturnSuspended(true)
        let imageURL = URL(fileURLWithPath: "/tmp/photo-return.png")
        let capture = Task { @MainActor in
            await model.captureReturnVisitPhoto(from: imageURL)
        }
        await port.waitForPhotoReturnStart()

        #expect(model.state == .waitingReturn)
        #expect(model.scoreEvidence == nil)

        await port.releasePhotoReturn(.noUsableFace)
        await capture.value
        #expect(model.state == .ready)
        #expect(model.scoreEvidence == nil)
        #expect(model.statusMessage == DebugIdentityCalibrationModel.noUsableFaceMessage)
    }

    @Test("photo enrollment completion after stop remains stopped")
    func photoEnrollmentCompletionAfterStopRemainsStopped() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-photo")
        await port.seedCount(1, for: member)
        await port.setPhotoEnrollmentSuspended(true)
        await port.setPhotoStopCancelsPending(false)
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()
        model.memberIDInput = member.rawValue
        await model.selectTemporaryMember()

        let capture = Task { @MainActor in
            await model.captureEnrollmentPhoto(
                from: URL(fileURLWithPath: "/tmp/stop-race-enrollment.jpg")
            )
        }
        await port.waitForPhotoEnrollmentStart()
        await model.stopCamera()
        #expect(model.state == .stopped)

        await port.releasePhotoEnrollment(.stored)
        await capture.value

        #expect(model.state == .stopped)
        #expect(model.selectedSampleCount == 2)
        #expect(model.statusMessage == nil)
    }

    @Test("photo return completion after stop remains stopped")
    func photoReturnCompletionAfterStopRemainsStopped() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-photo")
        await port.setPhotoReturnSuspended(true)
        await port.setPhotoStopCancelsPending(false)
        await port.setPhotoReturnResult(.success(.measured(IdentityCalibrationEvidence(
            gallerySampleCount: 1,
            top1: IdentityCalibrationCandidate(
                memberID: member,
                cosineSimilarity: 0.9
            ),
            top2: nil
        ))))
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()

        let capture = Task { @MainActor in
            await model.captureReturnVisitPhoto(
                from: URL(fileURLWithPath: "/tmp/stop-race-return.jpg")
            )
        }
        await port.waitForPhotoReturnStart()
        await model.stopCamera()
        #expect(model.state == .stopped)

        await port.releasePhotoReturn(.measured(IdentityCalibrationEvidence(
            gallerySampleCount: 1,
            top1: IdentityCalibrationCandidate(
                memberID: member,
                cosineSimilarity: 0.9
            ),
            top2: nil
        )))
        await capture.value

        #expect(model.state == .stopped)
        #expect(model.scoreEvidence?.top1?.memberID == member.rawValue)
    }

    @Test("photo capture requires a selected member for enrollment")
    func photoEnrollmentRequiresSelectedMember() async throws {
        let port = RecordingIdentityCalibrationPort()
        let model = DebugIdentityCalibrationModel(port: port)

        await model.captureEnrollmentPhoto(
            from: URL(fileURLWithPath: "/tmp/no-member.png")
        )

        #expect(model.state == .stopped)
        #expect(await port.photoEnrollmentURLs.isEmpty)
    }

    @Test("photo and camera captures share the one-operation guard")
    func photoAndCameraCapturesCannotOverlap() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-photo")
        await port.seedCount(1, for: member)
        await port.setPhotoEnrollmentSuspended(true)
        let model = DebugIdentityCalibrationModel(port: port)
        model.memberIDInput = member.rawValue
        await model.selectTemporaryMember()

        let photo = Task { @MainActor in
            await model.captureEnrollmentPhoto(
                from: URL(fileURLWithPath: "/tmp/in-flight.jpg")
            )
        }
        await port.waitForPhotoEnrollmentStart()
        #expect(model.state == .waitingEnrollment)

        await model.captureReturnVisit()
        #expect(await port.returnCallCount == 0)
        #expect(model.state == .waitingEnrollment)

        await model.stopCamera()
        await photo.value
        #expect(model.state == .stopped)
        #expect(await port.stopCallCount == 1)
    }

    @Test("photo cancellation preserves stopped semantics and redacts errors")
    func photoCancellationStopsCamera() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-photo")
        await port.setPhotoEnrollmentResult(.failure(CancellationError()))
        let model = DebugIdentityCalibrationModel(port: port)
        model.memberIDInput = member.rawValue
        await model.selectTemporaryMember()

        await model.captureEnrollmentPhoto(
            from: URL(fileURLWithPath: "/tmp/cancel.jpg")
        )

        #expect(model.state == .stopped)
        #expect(model.statusMessage == nil)
        #expect(await port.stopCallCount == 1)
    }

    @Test("photo failure after a manual stop still shows fixed failure copy")
    func photoFailureAfterManualStopShowsFailureCopy() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-photo")
        await port.setPhotoEnrollmentResult(.failure(MarkerError.marker))
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()
        await model.stopCamera()
        model.memberIDInput = member.rawValue
        await model.selectTemporaryMember()

        await model.captureEnrollmentPhoto(
            from: URL(fileURLWithPath: "/tmp/stopped-failure.jpg")
        )

        #expect(model.state == .stopped)
        #expect(model.statusMessage == DebugIdentityCalibrationModel.genericFailureMessage)
    }

    @Test("return measurement maps full-gallery candidates and margin without selecting an ID")
    func returnMeasurementMapsEvidence() async throws {
        let port = RecordingIdentityCalibrationPort()
        let memberA = try MemberID(rawValue: "temporary-a")
        let memberB = try MemberID(rawValue: "temporary-b")
        await port.setReturnResult(.success(.measured(IdentityCalibrationEvidence(
            gallerySampleCount: 5,
            top1: IdentityCalibrationCandidate(
                memberID: memberA,
                cosineSimilarity: 0.94
            ),
            top2: IdentityCalibrationCandidate(
                memberID: memberB,
                cosineSimilarity: 0.81
            )
        ))))
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()

        await model.captureReturnVisit()

        #expect(model.state == .ready)
        #expect(model.selectedMemberID == nil)
        #expect(model.scoreEvidence?.gallerySampleCount == 5)
        #expect(model.scoreEvidence?.top1?.memberID == memberA.rawValue)
        #expect(model.scoreEvidence?.top1?.cosineSimilarity == 0.94)
        #expect(model.scoreEvidence?.top2?.memberID == memberB.rawValue)
        #expect(model.scoreEvidence?.top2?.cosineSimilarity == 0.81)
        #expect(abs((model.scoreEvidence?.margin ?? 0) - 0.13) < 0.000_001)
    }

    @Test("an empty measured gallery is valid evidence with no candidates")
    func emptyMeasuredGalleryIsValid() async throws {
        let port = RecordingIdentityCalibrationPort()
        await port.setReturnResult(.success(.measured(IdentityCalibrationEvidence(
            gallerySampleCount: 0,
            top1: nil,
            top2: nil
        ))))
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()

        await model.captureReturnVisit()

        #expect(model.state == .ready)
        #expect(model.scoreEvidence?.gallerySampleCount == 0)
        #expect(model.scoreEvidence?.top1 == nil)
        #expect(model.scoreEvidence?.top2 == nil)
        #expect(model.scoreEvidence?.margin == nil)
    }

    @Test("reset requires confirmation and only resets selected member")
    func resetRequiresConfirmationAndIsScoped() async throws {
        let port = RecordingIdentityCalibrationPort()
        let memberA = try MemberID(rawValue: "temporary-a")
        let memberB = try MemberID(rawValue: "temporary-b")
        await port.seedCount(2, for: memberA)
        await port.seedCount(4, for: memberB)
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()
        model.memberIDInput = memberA.rawValue
        await model.selectTemporaryMember()

        await port.setReturnResult(.success(.measured(IdentityCalibrationEvidence(
            gallerySampleCount: 6,
            top1: IdentityCalibrationCandidate(
                memberID: memberA,
                cosineSimilarity: 0.92
            ),
            top2: IdentityCalibrationCandidate(
                memberID: memberB,
                cosineSimilarity: 0.71
            )
        ))))
        await model.captureReturnVisit()
        #expect(model.scoreEvidence != nil)

        model.requestReset()
        #expect(model.isResetConfirmationPresented)
        model.cancelReset()
        #expect(model.isResetConfirmationPresented == false)
        #expect(await port.resetMemberIDs.isEmpty)

        model.requestReset()
        await model.confirmReset()

        #expect(model.isResetConfirmationPresented == false)
        #expect(model.selectedMemberID == memberA.rawValue)
        #expect(model.selectedSampleCount == 0)
        #expect(model.scoreEvidence == nil)
        #expect(await port.resetMemberIDs == [memberA])
        #expect(await port.counts[memberB] == 4)
    }

    @Test("one operation guard keeps return capture from overlapping enrollment")
    func oneOperationGuard() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-a")
        await port.seedCount(1, for: member)
        await port.setEnrollmentSuspended(true)
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()
        model.memberIDInput = member.rawValue
        await model.selectTemporaryMember()

        let enrollment = Task { @MainActor in
            await model.captureEnrollment()
        }
        await port.waitForEnrollmentStart()
        #expect(model.state == .waitingEnrollment)

        await model.captureReturnVisit()
        #expect(await port.returnCallCount == 0)
        #expect(model.state == .waitingEnrollment)

        await port.releaseEnrollment(.stored)
        await enrollment.value
        #expect(model.state == .ready)
    }

    @Test("stopping a pending capture calls stop and ends stopped without generic error")
    func stopCancelsPendingCaptureWithoutError() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-a")
        await port.seedCount(1, for: member)
        await port.setEnrollmentSuspended(true)
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()
        model.memberIDInput = member.rawValue
        await model.selectTemporaryMember()

        let capture = Task { @MainActor in
            await model.captureEnrollment()
        }
        await port.waitForEnrollmentStart()
        await model.stopCamera()
        await capture.value

        #expect(model.state == .stopped)
        #expect(model.statusMessage == nil)
        #expect(await port.stopCallCount == 1)
    }

    @Test("generic capture errors map to fixed copy without SDK details")
    func genericCaptureErrorIsRedacted() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-a")
        await port.seedCount(1, for: member)
        await port.setEnrollmentResult(.failure(MarkerError.marker))
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()
        model.memberIDInput = member.rawValue
        await model.selectTemporaryMember()

        await model.captureEnrollment()

        #expect(model.state == .ready)
        #expect(model.statusMessage == DebugIdentityCalibrationModel.genericFailureMessage)
        #expect(String(describing: model.state).contains("marker") == false)
    }

    @Test("a return no-face result clears prior score evidence")
    func returnNoFaceClearsPriorEvidence() async throws {
        let port = RecordingIdentityCalibrationPort()
        let member = try MemberID(rawValue: "temporary-a")
        await port.setReturnResult(.success(.measured(IdentityCalibrationEvidence(
            gallerySampleCount: 1,
            top1: IdentityCalibrationCandidate(
                memberID: member,
                cosineSimilarity: 0.88
            ),
            top2: nil
        ))))
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()
        await model.captureReturnVisit()
        #expect(model.scoreEvidence != nil)

        await port.setReturnResult(.success(.noUsableFace))
        await model.captureReturnVisit()

        #expect(model.state == .ready)
        #expect(model.scoreEvidence == nil)
    }

    @Test("count-load cancellation stops the camera before showing stopped")
    func countLoadCancellationStopsCamera() async throws {
        let port = RecordingIdentityCalibrationPort()
        await port.setSampleCountFailure(CancellationError())
        let model = DebugIdentityCalibrationModel(port: port)
        await model.startCamera()
        model.memberIDInput = "temporary-a"

        await model.selectTemporaryMember()

        #expect(model.state == .stopped)
        #expect(model.statusMessage == nil)
        #expect(await port.stopCallCount == 1)
    }

    private func acceptsSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}

private actor RecordingIdentityCalibrationPort: IdentityCalibrationPort {
    private var countsByMember: [MemberID: Int] = [:]
    private var enrollmentResult: Result<IdentityCalibrationCaptureResult, Error> = .success(.stored)
    private var photoEnrollmentResult: Result<IdentityCalibrationCaptureResult, Error> = .success(.stored)
    private var returnResult: Result<IdentityCalibrationReturnResult, Error> = .success(.measured(
        IdentityCalibrationEvidence(gallerySampleCount: 0, top1: nil, top2: nil)
    ))
    private var photoReturnResult: Result<IdentityCalibrationReturnResult, Error> = .success(.measured(
        IdentityCalibrationEvidence(gallerySampleCount: 0, top1: nil, top2: nil)
    ))
    private var startResult: Result<Void, Error> = .success(())
    private var sampleCountFailure: Error?
    private var startSuspended = false
    private var pendingStart: CheckedContinuation<Void, Error>?
    private var enrollmentSuspended = false
    private var pendingEnrollment: CheckedContinuation<IdentityCalibrationCaptureResult, Error>?
    private var photoEnrollmentSuspended = false
    private var pendingPhotoEnrollment: CheckedContinuation<IdentityCalibrationCaptureResult, Error>?
    private var photoReturnSuspended = false
    private var pendingPhotoReturn: CheckedContinuation<IdentityCalibrationReturnResult, Error>?
    private var photoStopCancelsPending = true
    private var enrollmentStarted = AsyncStream<Void>.makeStream(
        of: Void.self,
        bufferingPolicy: .bufferingNewest(1)
    )
    private var photoEnrollmentStarted = AsyncStream<Void>.makeStream(
        of: Void.self,
        bufferingPolicy: .bufferingNewest(1)
    )
    private var photoReturnStarted = AsyncStream<Void>.makeStream(
        of: Void.self,
        bufferingPolicy: .bufferingNewest(1)
    )
    private var startStarted = AsyncStream<Void>.makeStream(
        of: Void.self,
        bufferingPolicy: .bufferingNewest(1)
    )

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var sampleCountCalls: [MemberID] = []
    private(set) var enrollmentMemberIDs: [MemberID] = []
    private(set) var photoEnrollmentMemberIDs: [MemberID] = []
    private(set) var photoEnrollmentURLs: [URL] = []
    private(set) var photoEnrollmentDates: [Date] = []
    private(set) var photoReturnURLs: [URL] = []
    private(set) var resetMemberIDs: [MemberID] = []
    private(set) var returnCallCount = 0

    func startCamera() async throws {
        startCallCount += 1
        if startSuspended {
            startStarted.continuation.yield(())
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    pendingStart = continuation
                    if Task.isCancelled {
                        pendingStart = nil
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }, onCancel: {
                Task { await self.cancelPendingStart() }
            })
        }
        try startResult.get()
    }

    func stopCamera() async {
        stopCallCount += 1
        pendingEnrollment?.resume(throwing: CancellationError())
        pendingEnrollment = nil
        if photoStopCancelsPending {
            pendingPhotoEnrollment?.resume(throwing: CancellationError())
            pendingPhotoEnrollment = nil
            pendingPhotoReturn?.resume(throwing: CancellationError())
            pendingPhotoReturn = nil
        }
    }

    func captureEnrollmentSample(
        for temporaryMemberID: MemberID,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        _ = createdAt
        enrollmentMemberIDs.append(temporaryMemberID)
        if enrollmentSuspended {
            enrollmentStarted.continuation.yield(())
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    pendingEnrollment = continuation
                    if Task.isCancelled {
                        pendingEnrollment = nil
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }, onCancel: {
                Task { await self.cancelPendingEnrollment() }
            })
        }
        let result = try enrollmentResult.get()
        if case .stored = result {
            countsByMember[temporaryMemberID, default: 0] += 1
        }
        return result
    }

    func captureEnrollmentPhoto(
        for temporaryMemberID: MemberID,
        from imageURL: URL,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        _ = createdAt
        photoEnrollmentMemberIDs.append(temporaryMemberID)
        photoEnrollmentURLs.append(imageURL)
        photoEnrollmentDates.append(createdAt)
        if photoEnrollmentSuspended {
            photoEnrollmentStarted.continuation.yield(())
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    pendingPhotoEnrollment = continuation
                    if Task.isCancelled {
                        pendingPhotoEnrollment = nil
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }, onCancel: {
                Task { await self.cancelPendingPhotoEnrollment() }
            })
        }
        let result = try photoEnrollmentResult.get()
        if case .stored = result {
            countsByMember[temporaryMemberID, default: 0] += 1
        }
        return result
    }

    func captureReturnVisit() async throws -> IdentityCalibrationReturnResult {
        returnCallCount += 1
        return try returnResult.get()
    }

    func captureReturnVisitPhoto(
        from imageURL: URL
    ) async throws -> IdentityCalibrationReturnResult {
        photoReturnURLs.append(imageURL)
        if photoReturnSuspended {
            photoReturnStarted.continuation.yield(())
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    pendingPhotoReturn = continuation
                    if Task.isCancelled {
                        pendingPhotoReturn = nil
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }, onCancel: {
                Task { await self.cancelPendingPhotoReturn() }
            })
        }
        return try photoReturnResult.get()
    }

    func sampleCount(for temporaryMemberID: MemberID) async throws -> Int {
        sampleCountCalls.append(temporaryMemberID)
        if let sampleCountFailure {
            throw sampleCountFailure
        }
        return countsByMember[temporaryMemberID, default: 0]
    }

    func reset(for temporaryMemberID: MemberID) async throws {
        resetMemberIDs.append(temporaryMemberID)
        countsByMember[temporaryMemberID] = 0
    }

    func seedCount(_ count: Int, for memberID: MemberID) {
        countsByMember[memberID] = count
    }

    func setStartFailure(_ error: Error) {
        startResult = .failure(error)
    }

    func setStartSuspended(_ suspended: Bool) {
        startSuspended = suspended
    }

    func setEnrollmentResult(
        _ result: Result<IdentityCalibrationCaptureResult, Error>
    ) {
        enrollmentResult = result
    }

    func setPhotoEnrollmentResult(
        _ result: Result<IdentityCalibrationCaptureResult, Error>
    ) {
        photoEnrollmentResult = result
    }

    func setSampleCountFailure(_ error: Error) {
        sampleCountFailure = error
    }

    func setReturnResult(
        _ result: Result<IdentityCalibrationReturnResult, Error>
    ) {
        returnResult = result
    }

    func setPhotoReturnResult(
        _ result: Result<IdentityCalibrationReturnResult, Error>
    ) {
        photoReturnResult = result
    }

    func setEnrollmentSuspended(_ suspended: Bool) {
        enrollmentSuspended = suspended
    }

    func setPhotoEnrollmentSuspended(_ suspended: Bool) {
        photoEnrollmentSuspended = suspended
    }

    func setPhotoReturnSuspended(_ suspended: Bool) {
        photoReturnSuspended = suspended
    }

    func setPhotoStopCancelsPending(_ cancels: Bool) {
        photoStopCancelsPending = cancels
    }

    func waitForEnrollmentStart() async {
        var iterator = enrollmentStarted.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitForPhotoEnrollmentStart() async {
        var iterator = photoEnrollmentStarted.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitForPhotoReturnStart() async {
        var iterator = photoReturnStarted.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitForStart() async {
        var iterator = startStarted.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func releaseStart() {
        pendingStart?.resume()
        pendingStart = nil
    }

    func releaseEnrollment(_ result: IdentityCalibrationCaptureResult) {
        pendingEnrollment?.resume(returning: result)
        pendingEnrollment = nil
    }

    func releasePhotoEnrollment(_ result: IdentityCalibrationCaptureResult) {
        pendingPhotoEnrollment?.resume(returning: result)
        pendingPhotoEnrollment = nil
    }

    func releasePhotoReturn(_ result: IdentityCalibrationReturnResult) {
        pendingPhotoReturn?.resume(returning: result)
        pendingPhotoReturn = nil
    }

    var counts: [MemberID: Int] { countsByMember }

    private func cancelPendingEnrollment() {
        pendingEnrollment?.resume(throwing: CancellationError())
        pendingEnrollment = nil
    }

    private func cancelPendingPhotoEnrollment() {
        pendingPhotoEnrollment?.resume(throwing: CancellationError())
        pendingPhotoEnrollment = nil
    }

    private func cancelPendingPhotoReturn() {
        pendingPhotoReturn?.resume(throwing: CancellationError())
        pendingPhotoReturn = nil
    }

    private func cancelPendingStart() {
        pendingStart?.resume(throwing: CancellationError())
        pendingStart = nil
    }
}

private enum MarkerError: Error {
    case marker
}

#endif
