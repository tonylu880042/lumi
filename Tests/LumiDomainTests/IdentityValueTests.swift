import LumiDomain
import Testing

@Test("member ID rejects an empty raw value with a typed error")
func memberIDRejectsEmptyRawValue() {
    do {
        _ = try MemberID(rawValue: "")
        Issue.record("Expected an empty member ID to be rejected")
    } catch let error as MemberIDError {
        #expect(error == .empty)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test("member ID preserves every non-empty raw string exactly")
func memberIDPreservesExactRawString() throws {
    let rawValue = "  member-001  "
    let memberID = try MemberID(rawValue: rawValue)
    let sameID = try MemberID(rawValue: rawValue)

    #expect(memberID.rawValue == rawValue)
    #expect(memberID == sameID)
}

@Test("member ID is hashable, equatable, and sendable")
func memberIDConformanceContract() throws {
    let memberID = try MemberID(rawValue: "member-001")
    let sameID = try MemberID(rawValue: "member-001")

    #expect(memberID == sameID)
    #expect(Set([memberID]).contains(sameID))
    acceptsSendable(memberID)
}

@Test("recognition confidence accepts inclusive zero and one boundaries")
func recognitionConfidenceAcceptsInclusiveBoundaries() throws {
    for value in [0.0, 1.0] {
        let confidence = try RecognitionConfidence(value: value)
        #expect(confidence.value == value)
    }
}

@Test("recognition confidence rejects values just outside both boundaries")
func recognitionConfidenceRejectsValuesOutsideBoundaries() {
    let values = [-Double.leastNonzeroMagnitude, 1.0.nextUp]

    for value in values {
        do {
            _ = try RecognitionConfidence(value: value)
            Issue.record("Expected out-of-range confidence to be rejected: \(value)")
        } catch let error as RecognitionConfidenceError {
            #expect(error == .outOfRange(value: value))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

@Test("recognition confidence rejects NaN and infinities with a typed error")
func recognitionConfidenceRejectsNonFiniteValues() {
    for value in [Double.nan, Double.infinity, -Double.infinity] {
        do {
            _ = try RecognitionConfidence(value: value)
            Issue.record("Expected non-finite confidence to be rejected: \(value)")
        } catch let error as RecognitionConfidenceError {
            #expect(error == .nonFinite)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

@Test("recognition confidence compares by its validated value")
func recognitionConfidenceComparison() throws {
    let lower = try RecognitionConfidence(value: 0.25)
    let higher = try RecognitionConfidence(value: 0.75)

    #expect(lower < higher)
    #expect(higher > lower)
    let sameLower = try RecognitionConfidence(value: 0.25)
    #expect(lower == sameLower)
}

@Test("recognition confidence is sendable")
func recognitionConfidenceIsSendable() throws {
    acceptsSendable(try RecognitionConfidence(value: 0.5))
}

@Test("recognition results expose known identity or unknown without policy reasons")
func recognitionResultContract() throws {
    let memberID = try MemberID(rawValue: "member-001")
    let confidence = try RecognitionConfidence(value: 0.9)
    let known = RecognitionResult.known(memberID: memberID, confidence: confidence)

    #expect(known == .known(memberID: memberID, confidence: confidence))
    #expect(known != .unknown)
    #expect(RecognitionResult.unknown == .unknown)
    acceptsSendable(known)
    acceptsSendable(RecognitionResult.unknown)
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
