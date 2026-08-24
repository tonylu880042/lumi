/// One model-independent member candidate produced by Infrastructure.
public struct RecognitionMatchCandidate: Equatable, Sendable {
    public let memberID: MemberID
    public let similarity: Double

    public init(
        memberID: MemberID,
        similarity: Double
    ) throws(RecognitionMatchCandidateError) {
        guard similarity.isFinite else {
            throw .nonFinite
        }
        guard (-1.0...1.0).contains(similarity) else {
            throw .outOfRange
        }
        self.memberID = memberID
        self.similarity = similarity
    }
}

public enum RecognitionMatchCandidateError: Error, Equatable, Sendable {
    case nonFinite
    case outOfRange
}

/// One fresh-frame recognition observation with no Vision or Core ML types.
public enum RecognitionObservation: Equatable, Sendable {
    case noUsableFace
    case noCandidates
    case ranked(
        best: RecognitionMatchCandidate,
        second: RecognitionMatchCandidate?
    )
}

/// Internal policy diagnostics. Application must map these to public unknown.
public enum UnknownReason: Equatable, Sendable {
    case noUsableFace
    case noCandidates
    case scoreBelowThreshold
    case ambiguousCandidates
    case inconsistentObservations
    case insufficientObservations
    case invalidEvidence
}

/// The Domain decision before Application removes internal unknown reasons.
public enum RecognitionDecision: Equatable, Sendable {
    case known(memberID: MemberID, confidence: RecognitionConfidence)
    case unknown(reason: UnknownReason)
}

public struct RecognitionConfidencePolicyConfiguration: Equatable, Sendable {
    public let acceptThreshold: Double
    public let minimumMargin: Double
    public let observationCount: Int
    public let requiredConfirmations: Int

    public init(
        acceptThreshold: Double,
        minimumMargin: Double,
        observationCount: Int,
        requiredConfirmations: Int
    ) throws(RecognitionConfidencePolicyConfigurationError) {
        guard acceptThreshold.isFinite,
              (0.0...1.0).contains(acceptThreshold),
              minimumMargin.isFinite,
              (0.0...2.0).contains(minimumMargin),
              observationCount > 0,
              requiredConfirmations > 0,
              requiredConfirmations <= observationCount
        else {
            throw .invalid
        }

        self.acceptThreshold = acceptThreshold
        self.minimumMargin = minimumMargin
        self.observationCount = observationCount
        self.requiredConfirmations = requiredConfirmations
    }

    /// Owner-approved 44B physical-device pilot values.
    ///
    /// These values are not a production validation claim. Release composition
    /// must not enable them until ADR-0004's dataset exit criteria are met.
    public static let pilot44B = RecognitionConfidencePolicyConfiguration(
        validatedAcceptThreshold: 0.70,
        minimumMargin: 0.20,
        observationCount: 3,
        requiredConfirmations: 2
    )

    private init(
        validatedAcceptThreshold: Double,
        minimumMargin: Double,
        observationCount: Int,
        requiredConfirmations: Int
    ) {
        acceptThreshold = validatedAcceptThreshold
        self.minimumMargin = minimumMargin
        self.observationCount = observationCount
        self.requiredConfirmations = requiredConfirmations
    }
}

public enum RecognitionConfidencePolicyConfigurationError:
    Error,
    Equatable,
    Sendable
{
    case invalid
}

/// Deterministic, SDK-independent confidence policy.
public struct RecognitionConfidencePolicy: Sendable {
    private let configuration: RecognitionConfidencePolicyConfiguration

    public init(configuration: RecognitionConfidencePolicyConfiguration) {
        self.configuration = configuration
    }

    public func decide(
        observations: [RecognitionObservation]
    ) -> RecognitionDecision {
        guard observations.count == configuration.observationCount else {
            return .unknown(reason: .insufficientObservations)
        }

        var acceptedScores: [MemberID: [Double]] = [:]
        var sawRankedFace = false
        var sawNoCandidates = false
        var sawLowScore = false
        var sawAmbiguousCandidate = false

        for observation in observations {
            if case .noCandidates = observation {
                sawNoCandidates = true
                continue
            }
            guard case let .ranked(best, second) = observation else {
                continue
            }
            sawRankedFace = true

            guard best.similarity >= configuration.acceptThreshold else {
                sawLowScore = true
                continue
            }
            // The ambiguity gate protects against a competing member, not
            // multiple gallery samples belonging to the same member. The
            // matcher normally aggregates by MemberID, but the Domain policy
            // remains safe when a lower layer supplies duplicate-member
            // evidence or no second candidate at all.
            if let second, second.memberID != best.memberID {
                let margin = best.similarity - second.similarity
                let scale = max(
                    1.0,
                    abs(best.similarity),
                    abs(second.similarity),
                    abs(configuration.minimumMargin)
                )
                let roundingTolerance = 4 * Double.ulpOfOne * scale
                guard margin + roundingTolerance >= configuration.minimumMargin else {
                    sawAmbiguousCandidate = true
                    continue
                }
            }

            acceptedScores[best.memberID, default: []].append(best.similarity)
        }

        let confirmed = acceptedScores
            .filter { $0.value.count >= configuration.requiredConfirmations }
            .sorted { $0.key.rawValue < $1.key.rawValue }

        if confirmed.count == 1,
           let member = confirmed.first,
           let lowestScore = member.value.min(),
           let confidence = try? RecognitionConfidence(value: lowestScore)
        {
            return .known(memberID: member.key, confidence: confidence)
        }

        if !acceptedScores.isEmpty {
            return .unknown(reason: .inconsistentObservations)
        }
        if sawAmbiguousCandidate {
            return .unknown(reason: .ambiguousCandidates)
        }
        if sawLowScore {
            return .unknown(reason: .scoreBelowThreshold)
        }
        if sawRankedFace {
            return .unknown(reason: .invalidEvidence)
        }
        if sawNoCandidates {
            return .unknown(reason: .noCandidates)
        }
        return .unknown(reason: .noUsableFace)
    }
}
