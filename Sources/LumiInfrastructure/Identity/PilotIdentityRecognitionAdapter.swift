#if DEBUG

import LumiApplication
import LumiDomain

/// Minimal evidence source used by the 44B pilot adapter.
///
/// Implementations keep camera frames, embeddings, and SDK values inside
/// Infrastructure. Each capture must measure one newly armed camera frame.
public protocol PilotRecognitionEvidenceSource: Sendable {
    func startCamera() async throws
    func stopCamera() async
    func captureReturnVisit() async throws -> IdentityCalibrationReturnResult
}

public enum PilotIdentityRecognitionError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case operationInProgress
    case failed

    public var description: String {
        "Pilot identity recognition failed."
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}

/// DEBUG-only bridge from the validated calibration graph to the existing
/// `IdentityRecognitionPort`.
///
/// The adapter captures exactly the policy's three fresh observations, stops
/// the camera, and exposes only known/unknown. Pilot policy reasons and raw
/// scores never cross the Application port.
public actor PilotIdentityRecognitionAdapter: IdentityRecognitionPort {
    private let source: any PilotRecognitionEvidenceSource
    private let policy = RecognitionConfidencePolicy(configuration: .pilot44B)
    private var recognitionInProgress = false

    public init(source: any PilotRecognitionEvidenceSource) {
        self.source = source
    }

    public func recognizeCurrentVisitor() async throws -> RecognitionResult {
        guard !recognitionInProgress else {
            throw PilotIdentityRecognitionError.operationInProgress
        }
        recognitionInProgress = true
        defer { recognitionInProgress = false }

        do {
            try Task.checkCancellation()
            try await source.startCamera()
            try Task.checkCancellation()

            var observations: [RecognitionObservation] = []
            observations.reserveCapacity(
                RecognitionConfidencePolicyConfiguration.pilot44B.observationCount
            )
            for _ in 0..<RecognitionConfidencePolicyConfiguration.pilot44B.observationCount {
                let result = try await source.captureReturnVisit()
                try Task.checkCancellation()
                observations.append(try Self.map(result))
            }

            await source.stopCamera()
            try Task.checkCancellation()
            return Self.map(policy.decide(observations: observations))
        } catch let cancellation as CancellationError {
            await source.stopCamera()
            throw cancellation
        } catch {
            await source.stopCamera()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw PilotIdentityRecognitionError.failed
        }
    }

    private static func map(
        _ result: IdentityCalibrationReturnResult
    ) throws -> RecognitionObservation {
        switch result {
        case .noUsableFace:
            return .noUsableFace
        case let .measured(evidence):
            guard let top1 = evidence.top1 else {
                return .noCandidates
            }
            let best = try RecognitionMatchCandidate(
                memberID: top1.memberID,
                similarity: top1.cosineSimilarity
            )
            let second: RecognitionMatchCandidate?
            if let top2 = evidence.top2 {
                second = try RecognitionMatchCandidate(
                    memberID: top2.memberID,
                    similarity: top2.cosineSimilarity
                )
            } else {
                second = nil
            }
            return .ranked(best: best, second: second)
        }
    }

    private static func map(_ decision: RecognitionDecision) -> RecognitionResult {
        switch decision {
        case let .known(memberID, confidence):
            .known(memberID: memberID, confidence: confidence)
        case .unknown:
            .unknown
        }
    }
}

extension CoreMLIdentityCalibrationService: PilotRecognitionEvidenceSource {}

#endif
