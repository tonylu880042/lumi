import Testing
import LumiDomain

@Test("rotation angle accepts inclusive safety boundaries and zero")
func rotationAngleAcceptsBoundaries() throws {
    for degrees in [-90.0, 0.0, 90.0] {
        let angle = try RotationAngle(degrees: degrees)
        #expect(angle.degrees == degrees)
    }
}

@Test("rotation angle rejects non-finite values with a typed error")
func rotationAngleRejectsNonFiniteValues() {
    for degrees in [Double.nan, Double.infinity, -Double.infinity] {
        do {
            _ = try RotationAngle(degrees: degrees)
            Issue.record("Expected non-finite angle to be rejected: \(degrees)")
        } catch let error as RotationAngleError {
            #expect(error == .nonFinite)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

@Test("rotation angle rejects values just outside both safety boundaries")
func rotationAngleRejectsOutOfRangeValues() {
    for degrees in [-90.0001, 90.0001] {
        do {
            _ = try RotationAngle(degrees: degrees)
            Issue.record("Expected out-of-range angle to be rejected: \(degrees)")
        } catch let error as RotationAngleError {
            #expect(error == .outOfRange(degrees: degrees))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

@Test("rotation angle is an Equatable Sendable value")
func rotationAngleIsEquatableAndSendable() throws {
    let first = try RotationAngle(degrees: 15)
    let second = try RotationAngle(degrees: 15)

    #expect(first == second)
    acceptsSendable(first)
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
