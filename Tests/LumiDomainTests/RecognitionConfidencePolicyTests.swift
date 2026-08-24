import LumiDomain
import Testing

@Suite("Recognition confidence policy")
struct RecognitionConfidencePolicyTests {
    @Test("44B pilot configuration pins the approved temporary gates")
    func pilotConfiguration() {
        let configuration = RecognitionConfidencePolicyConfiguration.pilot44B

        #expect(configuration.acceptThreshold == 0.70)
        #expect(configuration.minimumMargin == 0.20)
        #expect(configuration.observationCount == 3)
        #expect(configuration.requiredConfirmations == 2)
    }

    @Test("two of three clear observations resolve the same member")
    func acceptsTwoOfThree() throws {
        let tony = try MemberID(rawValue: "tony")
        let ruby = try MemberID(rawValue: "ruby")
        let policy = RecognitionConfidencePolicy(configuration: .pilot44B)

        let decision = policy.decide(observations: [
            try ranked(best: tony, score: 0.84, second: ruby, secondScore: 0.30),
            try ranked(best: tony, score: 0.76, second: ruby, secondScore: 0.40),
            try ranked(best: ruby, score: 0.73, second: tony, secondScore: 0.48),
        ])

        let confidence = try RecognitionConfidence(value: 0.76)
        #expect(decision == .known(memberID: tony, confidence: confidence))
    }

    @Test("known confidence is the lowest accepted score for the confirmed member")
    func knownConfidenceIsConservative() throws {
        let tony = try MemberID(rawValue: "tony")
        let ruby = try MemberID(rawValue: "ruby")
        let policy = RecognitionConfidencePolicy(configuration: .pilot44B)

        let decision = policy.decide(observations: [
            try ranked(best: tony, score: 0.91, second: ruby, secondScore: 0.20),
            try ranked(best: tony, score: 0.72, second: ruby, secondScore: 0.10),
            try ranked(best: tony, score: 0.88, second: ruby, secondScore: 0.30),
        ])

        let confidence = try RecognitionConfidence(value: 0.72)
        #expect(decision == .known(memberID: tony, confidence: confidence))
    }

    @Test("score and margin equality pass the approved boundaries")
    func acceptsExactBoundaries() throws {
        let tony = try MemberID(rawValue: "tony")
        let ruby = try MemberID(rawValue: "ruby")
        let policy = RecognitionConfidencePolicy(configuration: .pilot44B)

        let observation = try ranked(
            best: tony,
            score: 0.70,
            second: ruby,
            secondScore: 0.50
        )
        let decision = policy.decide(observations: [observation, observation, .noUsableFace])

        let confidence = try RecognitionConfidence(value: 0.70)
        #expect(decision == .known(memberID: tony, confidence: confidence))
    }

    @Test("score immediately below the gate remains unknown")
    func rejectsLowScore() throws {
        let tony = try MemberID(rawValue: "tony")
        let ruby = try MemberID(rawValue: "ruby")
        let policy = RecognitionConfidencePolicy(configuration: .pilot44B)
        let low = try ranked(
            best: tony,
            score: 0.70.nextDown,
            second: ruby,
            secondScore: 0.10
        )

        #expect(policy.decide(observations: [low, low, low]) == .unknown(
            reason: .scoreBelowThreshold
        ))
    }

    @Test("margin immediately below the gate remains unknown")
    func rejectsAmbiguousMargin() throws {
        let tony = try MemberID(rawValue: "tony")
        let ruby = try MemberID(rawValue: "ruby")
        let policy = RecognitionConfidencePolicy(configuration: .pilot44B)
        let ambiguous = try ranked(
            best: tony,
            score: 0.80,
            second: ruby,
            secondScore: 0.600_000_000_001
        )

        #expect(policy.decide(observations: [ambiguous, ambiguous, ambiguous]) == .unknown(
            reason: .ambiguousCandidates
        ))
    }

    @Test("a single candidate does not require a second-member margin")
    func acceptsSingleCandidateWithoutSecondMember() throws {
        let tony = try MemberID(rawValue: "tony")
        let policy = RecognitionConfidencePolicy(configuration: .pilot44B)
        let observation = RecognitionObservation.ranked(
            best: try RecognitionMatchCandidate(memberID: tony, similarity: 0.90),
            second: nil
        )

        let confidence = try RecognitionConfidence(value: 0.90)
        #expect(policy.decide(observations: [observation, observation, observation]) == .known(
            memberID: tony,
            confidence: confidence
        ))
    }

    @Test("a same-member second sample does not create inter-member ambiguity")
    func acceptsSameMemberSecondCandidateWithoutMargin() throws {
        let tony = try MemberID(rawValue: "tony")
        let policy = RecognitionConfidencePolicy(configuration: .pilot44B)
        let observation = try RecognitionObservation.ranked(
            best: RecognitionMatchCandidate(memberID: tony, similarity: 0.90),
            second: RecognitionMatchCandidate(memberID: tony, similarity: 0.89)
        )

        let confidence = try RecognitionConfidence(value: 0.90)
        #expect(policy.decide(observations: [observation, observation, observation]) == .known(
            memberID: tony,
            confidence: confidence
        ))
    }

    @Test("one accepted observation is insufficient for identity")
    func rejectsOneOfThree() throws {
        let tony = try MemberID(rawValue: "tony")
        let ruby = try MemberID(rawValue: "ruby")
        let policy = RecognitionConfidencePolicy(configuration: .pilot44B)

        #expect(policy.decide(observations: [
            try ranked(best: tony, score: 0.84, second: ruby, secondScore: 0.30),
            .noUsableFace,
            .noUsableFace,
        ]) == .unknown(reason: .inconsistentObservations))
    }

    @Test("wrong observation count is never evaluated as known")
    func rejectsWrongObservationCount() throws {
        let tony = try MemberID(rawValue: "tony")
        let ruby = try MemberID(rawValue: "ruby")
        let policy = RecognitionConfidencePolicy(configuration: .pilot44B)
        let observation = try ranked(
            best: tony,
            score: 0.84,
            second: ruby,
            secondScore: 0.30
        )

        #expect(policy.decide(observations: [observation, observation]) == .unknown(
            reason: .insufficientObservations
        ))
    }

    @Test("no usable faces remain a normal unknown result")
    func rejectsNoUsableFaces() {
        let policy = RecognitionConfidencePolicy(configuration: .pilot44B)

        #expect(policy.decide(observations: [
            .noUsableFace,
            .noUsableFace,
            .noUsableFace,
        ]) == .unknown(reason: .noUsableFace))
    }

    @Test("usable faces without enrolled candidates remain unknown")
    func rejectsEmptyGallery() {
        let policy = RecognitionConfidencePolicy(configuration: .pilot44B)

        #expect(policy.decide(observations: [
            .noCandidates,
            .noCandidates,
            .noCandidates,
        ]) == .unknown(reason: .noCandidates))
    }

    @Test("candidate similarity rejects nonfinite and out-of-range values")
    func validatesSimilarity() throws {
        let memberID = try MemberID(rawValue: "tony")

        #expect(throws: RecognitionMatchCandidateError.nonFinite) {
            _ = try RecognitionMatchCandidate(memberID: memberID, similarity: .nan)
        }
        #expect(throws: RecognitionMatchCandidateError.outOfRange) {
            _ = try RecognitionMatchCandidate(memberID: memberID, similarity: 1.01)
        }
    }
}

private func ranked(
    best: MemberID,
    score: Double,
    second: MemberID,
    secondScore: Double
) throws -> RecognitionObservation {
    .ranked(
        best: try RecognitionMatchCandidate(memberID: best, similarity: score),
        second: try RecognitionMatchCandidate(memberID: second, similarity: secondScore)
    )
}
