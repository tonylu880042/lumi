import LumiApplication
import Testing

@Suite("Device authorization token")
struct DeviceAuthorizationTokenTests {
    private let validRawValue = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY"

    @Test("accepts an unpadded base64url token with exactly 32 decoded bytes")
    func acceptsExactTokenAndPreservesRawValue() {
        let token = DeviceAuthorizationToken(rawValue: validRawValue)

        #expect(token != nil)
        #expect(token?.rawValue == validRawValue)
    }

    @Test("rejects empty, padded, non-base64url, and non-ASCII values")
    func rejectsInvalidAlphabetAndPadding() {
        let invalidValues = [
            "",
            "\(validRawValue)=",
            "+\(validRawValue.dropFirst())",
            "/\(validRawValue.dropFirst())",
            "\(validRawValue.prefix(21)) \(validRawValue.dropFirst(22))",
            "\(validRawValue.prefix(21))\n\(validRawValue.dropFirst(21))",
            "\(validRawValue.prefix(21))Ａ\(validRawValue.dropFirst(22))",
        ]

        for value in invalidValues {
            #expect(DeviceAuthorizationToken(rawValue: value) == nil)
        }
    }

    @Test("rejects values whose decoded length is not exactly 32 bytes")
    func rejectsWrongDecodedLength() {
        let thirtyOneBytes = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ"
        let thirtyThreeBytes = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB"

        #expect(DeviceAuthorizationToken(rawValue: thirtyOneBytes) == nil)
        #expect(DeviceAuthorizationToken(rawValue: thirtyThreeBytes) == nil)
    }

    @Test("rejects a non-canonical final base64url character")
    func rejectsNonCanonicalTrailingBits() {
        let nonCanonical = String(validRawValue.dropLast()) + "Z"

        #expect(DeviceAuthorizationToken(rawValue: nonCanonical) == nil)
    }

    @Test("accepts canonical final-character variants")
    func acceptsCanonicalTrailingBits() {
        let canonicalValues = [
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE",
            "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI",
            "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM",
        ]

        for value in canonicalValues {
            #expect(DeviceAuthorizationToken(rawValue: value) != nil)
        }
    }

    @Test("redacts textual and reflected representations")
    func redactsAllInspectableRepresentations() {
        let token = DeviceAuthorizationToken(rawValue: validRawValue)!
        let description = String(describing: token)
        let debugDescription = String(reflecting: token)
        let mirror = Mirror(reflecting: token)
        let reflectedChildren = mirror.children.map { String(describing: $0.value) }

        #expect(description == "<redacted>")
        #expect(debugDescription == "<redacted>")
        #expect(reflectedChildren == ["<redacted>"])
        #expect(!description.contains(validRawValue))
        #expect(!debugDescription.contains(validRawValue))
        #expect(!reflectedChildren.joined().contains(validRawValue))
    }

    @Test("is equatable and sendable")
    func supportsValueSemanticsAndConcurrency() {
        let first = DeviceAuthorizationToken(rawValue: validRawValue)!
        let second = DeviceAuthorizationToken(rawValue: validRawValue)!

        #expect(first == second)
        acceptsSendable(first)
    }

    @Test("store exposes async load save and remove operations")
    func storeContractIsUsable() async throws {
        let store = InMemoryDeviceAuthorizationStore()
        let token = DeviceAuthorizationToken(rawValue: validRawValue)!
        let port: any DeviceAuthorizationStore = store

        #expect(try await port.load() == nil)
        try await port.save(token)
        #expect(try await port.load() == token)
        try await port.remove()
        #expect(try await port.load() == nil)
    }
}

private actor InMemoryDeviceAuthorizationStore: DeviceAuthorizationStore {
    private var token: DeviceAuthorizationToken?

    func load() async throws -> DeviceAuthorizationToken? {
        token
    }

    func save(_ token: DeviceAuthorizationToken) async throws {
        self.token = token
    }

    func remove() async throws {
        token = nil
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
