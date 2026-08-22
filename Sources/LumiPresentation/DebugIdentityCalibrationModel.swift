#if DEBUG

import Foundation
import LumiApplication
import LumiDomain
import Observation

/// The user-visible lifecycle of the DEBUG identity calibration tool.
public enum DebugIdentityCalibrationState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case waitingEnrollment
    case waitingReturn
    case error(message: String)
}

/// Presentation-owned score evidence. Domain `MemberID` values are mapped to
/// strings before they reach the future DEBUG calibration view.
public struct DebugIdentityCalibrationCandidate: Equatable, Sendable {
    public let memberID: String
    public let cosineSimilarity: Double

    public init(memberID: String, cosineSimilarity: Double) {
        self.memberID = memberID
        self.cosineSimilarity = cosineSimilarity
    }
}

/// Presentation-owned, score-only return-visit evidence. This is calibration
/// output, not a known/unknown identity decision.
public struct DebugIdentityCalibrationEvidence: Equatable, Sendable {
    public let gallerySampleCount: Int
    public let top1: DebugIdentityCalibrationCandidate?
    public let top2: DebugIdentityCalibrationCandidate?

    public init(
        gallerySampleCount: Int,
        top1: DebugIdentityCalibrationCandidate?,
        top2: DebugIdentityCalibrationCandidate?
    ) {
        self.gallerySampleCount = gallerySampleCount
        self.top1 = top1
        self.top2 = top2
    }

    public var margin: Double? {
        guard let top1, let top2 else { return nil }
        return top1.cosineSimilarity - top2.cosineSimilarity
    }
}

/// Presentation-owned transient camera preview value.
///
/// The bytes are immutable, upright, non-mirrored BGRA8 data supplied only for
/// the active DEBUG preview. This model does not persist, log, or encode the
/// bytes.
public struct DebugIdentityCalibrationPreviewFrame: Equatable, Sendable {
    public let bgraBytes: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public init(
        bgraBytes: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) {
        self.bgraBytes = bgraBytes
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    public init(preview: IdentityCalibrationPreviewFrame) {
        self.init(
            bgraBytes: preview.bgraBytes,
            width: preview.width,
            height: preview.height,
            bytesPerRow: preview.bytesPerRow
        )
    }
}

/// DEBUG-only Presentation model for manual identity calibration.
///
/// It exposes only editable IDs, transient preview metadata, sample counts,
/// and score evidence. Camera, Vision, Core ML, SQLite, embeddings, and
/// recognition-policy diagnostics remain behind `IdentityCalibrationPort`.
@MainActor
@Observable
public final class DebugIdentityCalibrationModel {
    public typealias State = DebugIdentityCalibrationState

    public static let genericFailureMessage = "校準失敗，請再試一次"
    public static let invalidMemberIDMessage = "請輸入臨時會員 ID"
    public static let noSampleStoredMessage = "這次沒有儲存樣本"
    public static let noUsableFaceMessage = "沒有偵測到可用人臉"

    public private(set) var state: DebugIdentityCalibrationState = .stopped
    public var memberIDInput = ""
    public private(set) var selectedMemberID: String?
    public private(set) var selectedSampleCount = 0
    public private(set) var scoreEvidence: DebugIdentityCalibrationEvidence?
    public private(set) var previewFrame: DebugIdentityCalibrationPreviewFrame?
    public private(set) var statusMessage: String?
    public private(set) var isResetConfirmationPresented = false

    @ObservationIgnored
    private let port: any IdentityCalibrationPort

    @ObservationIgnored
    private var operationInFlight = false

    @ObservationIgnored
    private var stopRequested = false

    @ObservationIgnored
    private var previewObservationTask: Task<Void, Never>?

    @ObservationIgnored
    private var previewGeneration: UInt64 = 0

    public init(port: any IdentityCalibrationPort) {
        self.port = port
    }

    /// Starts the camera through the Application port. Only this operation's
    /// failure enters `.error`; capture/query failures retain camera readiness
    /// and surface fixed status copy for an easy retry.
    public func startCamera() async {
        guard !operationInFlight, canStart else { return }

        resetPreviewObservation()
        operationInFlight = true
        stopRequested = false
        state = .starting
        statusMessage = nil
        defer { operationInFlight = false }

        do {
            try Task.checkCancellation()
            try await port.startCamera()
            try Task.checkCancellation()
            if stopRequested {
                // `stopCamera()` can race a lazy App composition load. Once
                // the real port has finished starting, drain that side effect
                // before presenting `.stopped` to avoid leaving the camera on.
                await port.stopCamera()
                state = .stopped
            } else {
                state = .ready
                let previewStream = await port.previewFrames()
                observePreview(
                    previewStream,
                    generation: previewGeneration
                )
            }
        } catch let cancellation as CancellationError {
            _ = cancellation
            await stopAfterCancellation()
        } catch {
            if stopRequested || Task.isCancelled {
                resetPreviewObservation()
                state = .stopped
                statusMessage = nil
            } else {
                resetPreviewObservation()
                state = .error(message: Self.genericFailureMessage)
                statusMessage = nil
            }
        }
    }

    /// Stops the camera and cancels whichever port operation is awaiting its
    /// next frame. Selection and score evidence remain available for review.
    public func stopCamera() async {
        stopRequested = true
        resetPreviewObservation()
        isResetConfirmationPresented = false
        statusMessage = nil
        state = .stopped
        await port.stopCamera()
    }

    /// Loads the selected temporary member's current count. The input remains
    /// editable and switching IDs never resets return-visit score evidence.
    public func selectTemporaryMember() async {
        guard !operationInFlight, canQueryMemberCount else { return }

        guard !memberIDInput.isEmpty,
              let memberID = try? MemberID(rawValue: memberIDInput)
        else {
            statusMessage = Self.invalidMemberIDMessage
            return
        }

        let stateBeforeQuery = state
        operationInFlight = true
        statusMessage = nil
        defer { operationInFlight = false }

        do {
            try Task.checkCancellation()
            let count = try await port.sampleCount(for: memberID)
            try Task.checkCancellation()
            selectedMemberID = memberID.rawValue
            selectedSampleCount = count
            state = stateBeforeQuery
        } catch is CancellationError {
            await stopAfterCancellation()
        } catch {
            state = stateBeforeQuery
            statusMessage = Self.genericFailureMessage
        }
    }

    /// Confirms the editable member ID, refreshes its stored sample count, and
    /// starts the camera only after that identity context is ready. The result
    /// lets the DEBUG App advance to capture without inferring from transient
    /// lifecycle states.
    @discardableResult
    public func confirmMemberAndStartCamera() async -> Bool {
        let requestedMemberID = memberIDInput
        await selectTemporaryMember()

        guard selectedMemberID == requestedMemberID,
              statusMessage == nil else {
            return false
        }

        await startCamera()
        return state == .ready
    }

    /// Captures one fresh enrollment sample for the selected temporary ID.
    /// A successful store increments the loaded count locally; no follow-up
    /// count query is issued.
    public func captureEnrollment() async {
        guard !operationInFlight, state == .ready,
              let selectedMemberID,
              let memberID = try? MemberID(rawValue: selectedMemberID)
        else { return }

        operationInFlight = true
        state = .waitingEnrollment
        statusMessage = nil
        defer { operationInFlight = false }

        do {
            try Task.checkCancellation()
            let result = try await port.captureEnrollmentSample(
                for: memberID,
                at: Date()
            )
            switch result {
            case .stored:
                selectedSampleCount += 1
                scoreEvidence = nil
                state = .ready
            case .noUsableFace:
                state = .ready
                statusMessage = Self.noSampleStoredMessage
            }
        } catch is CancellationError {
            await stopAfterCancellation()
        } catch {
            state = stopRequested ? .stopped : .ready
            statusMessage = stopRequested ? nil : Self.genericFailureMessage
        }
    }

    /// Imports one transient enrollment image for the selected temporary ID.
    /// The encoded bytes are wrapped at this boundary for Application and are
    /// never retained by the Presentation model. Photo capture is allowed
    /// while the camera is stopped or ready and restores that prior state
    /// after completion.
    public func captureEnrollmentPhoto(from data: Data) async {
        guard !operationInFlight, canCapturePhoto,
              let selectedMemberID,
              let memberID = try? MemberID(rawValue: selectedMemberID)
        else { return }

        let stateBeforeCapture = state
        stopRequested = false
        operationInFlight = true
        state = .waitingEnrollment
        statusMessage = nil
        defer { operationInFlight = false }

        do {
            try Task.checkCancellation()
            let photo = IdentityCalibrationPhoto(data: data)
            let result = try await port.captureEnrollmentPhoto(
                for: memberID,
                from: photo,
                at: Date()
            )
            switch result {
            case .stored:
                selectedSampleCount += 1
                scoreEvidence = nil
                state = stopRequested ? .stopped : stateBeforeCapture
            case .noUsableFace:
                state = stopRequested ? .stopped : stateBeforeCapture
                statusMessage = stopRequested ? nil : Self.noSampleStoredMessage
            }
        } catch is CancellationError {
            await stopAfterCancellation()
        } catch {
            state = stopRequested ? .stopped : stateBeforeCapture
            statusMessage = stopRequested ? nil : Self.genericFailureMessage
        }
    }

    /// Captures one return-visit frame and maps score-only evidence for the
    /// full temporary gallery. No selected member is required or inferred.
    public func captureReturnVisit() async {
        guard !operationInFlight, state == .ready else { return }

        operationInFlight = true
        state = .waitingReturn
        statusMessage = nil
        scoreEvidence = nil
        defer { operationInFlight = false }

        do {
            try Task.checkCancellation()
            let result = try await port.captureReturnVisit()
            switch result {
            case .noUsableFace:
                state = .ready
                statusMessage = Self.noUsableFaceMessage
            case let .measured(evidence):
                scoreEvidence = Self.mapEvidence(evidence)
                state = .ready
            }
        } catch is CancellationError {
            await stopAfterCancellation()
        } catch {
            state = stopRequested ? .stopped : .ready
            statusMessage = stopRequested ? nil : Self.genericFailureMessage
        }
    }

    /// Imports one transient return-visit image and maps score-only evidence
    /// for the complete temporary gallery. No selected member is required;
    /// the encoded bytes are wrapped at this boundary and not retained by the
    /// model.
    public func captureReturnVisitPhoto(from data: Data) async {
        guard !operationInFlight, canCapturePhoto else { return }

        let stateBeforeCapture = state
        stopRequested = false
        operationInFlight = true
        state = .waitingReturn
        statusMessage = nil
        scoreEvidence = nil
        defer { operationInFlight = false }

        do {
            try Task.checkCancellation()
            let photo = IdentityCalibrationPhoto(data: data)
            let result = try await port.captureReturnVisitPhoto(from: photo)
            switch result {
            case .noUsableFace:
                state = stopRequested ? .stopped : stateBeforeCapture
                statusMessage = stopRequested ? nil : Self.noUsableFaceMessage
            case let .measured(evidence):
                scoreEvidence = Self.mapEvidence(evidence)
                state = stopRequested ? .stopped : stateBeforeCapture
            }
        } catch is CancellationError {
            await stopAfterCancellation()
        } catch {
            state = stopRequested ? .stopped : stateBeforeCapture
            statusMessage = stopRequested ? nil : Self.genericFailureMessage
        }
    }

    /// Requests confirmation for the currently selected temporary member.
    public func requestReset() {
        guard !operationInFlight,
              selectedMemberID != nil,
              state != .starting,
              state != .waitingEnrollment,
              state != .waitingReturn
        else { return }
        isResetConfirmationPresented = true
    }

    public func cancelReset() {
        isResetConfirmationPresented = false
    }

    /// Resets only the selected member after the explicit confirmation gate.
    /// The local count is cleared after the port side effect succeeds.
    public func confirmReset() async {
        guard !operationInFlight,
              isResetConfirmationPresented,
              let selectedMemberID,
              let memberID = try? MemberID(rawValue: selectedMemberID)
        else { return }

        let stateBeforeReset = state
        isResetConfirmationPresented = false
        operationInFlight = true
        statusMessage = nil
        defer { operationInFlight = false }

        do {
            try Task.checkCancellation()
            try await port.reset(for: memberID)
            selectedSampleCount = 0
            scoreEvidence = nil
            state = stateBeforeReset
        } catch is CancellationError {
            await stopAfterCancellation()
        } catch {
            state = stateBeforeReset
            statusMessage = Self.genericFailureMessage
        }
    }

    private var canStart: Bool {
        switch state {
        case .stopped, .error:
            return true
        case .starting, .ready, .waitingEnrollment, .waitingReturn:
            return false
        }
    }

    private var canQueryMemberCount: Bool {
        switch state {
        case .starting, .waitingEnrollment, .waitingReturn:
            return false
        case .stopped, .ready, .error:
            return true
        }
    }

    private var canCapturePhoto: Bool {
        switch state {
        case .stopped, .ready:
            return true
        case .starting, .waitingEnrollment, .waitingReturn, .error:
            return false
        }
    }

    private func stopAfterCancellation() async {
        resetPreviewObservation()
        if !stopRequested {
            stopRequested = true
            await port.stopCamera()
        }
        state = .stopped
        statusMessage = nil
    }

    private func observePreview(
        _ stream: AsyncStream<IdentityCalibrationPreviewFrame>,
        generation: UInt64
    ) {
        previewObservationTask?.cancel()
        previewObservationTask = Task { @MainActor [weak self] in
            for await preview in stream {
                guard !Task.isCancelled, let self,
                      self.previewGeneration == generation else {
                    return
                }
                self.previewFrame = DebugIdentityCalibrationPreviewFrame(
                    preview: preview
                )
            }

            guard let self,
                  self.previewGeneration == generation else {
                return
            }
            self.previewFrame = nil
            self.previewObservationTask = nil
        }
    }

    private func resetPreviewObservation() {
        previewGeneration &+= 1
        previewObservationTask?.cancel()
        previewObservationTask = nil
        previewFrame = nil
    }

    private static func mapEvidence(
        _ evidence: IdentityCalibrationEvidence
    ) -> DebugIdentityCalibrationEvidence {
        DebugIdentityCalibrationEvidence(
            gallerySampleCount: evidence.gallerySampleCount,
            top1: mapCandidate(evidence.top1),
            top2: mapCandidate(evidence.top2)
        )
    }

    private static func mapCandidate(
        _ candidate: IdentityCalibrationCandidate?
    ) -> DebugIdentityCalibrationCandidate? {
        guard let candidate else { return nil }
        return DebugIdentityCalibrationCandidate(
            memberID: candidate.memberID.rawValue,
            cosineSimilarity: candidate.cosineSimilarity
        )
    }
}

#endif
