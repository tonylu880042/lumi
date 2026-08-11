import Foundation
import LumiInfrastructure
import Testing

@Suite("OpenAI Realtime client secret")
struct OpenAIRealtimeClientSecretTests {
    @Test("preserves the exact non-empty value and expiration date")
    func storesExactValueAndExpiry() throws {
        let expiresAt = Date(timeIntervalSince1970: 1_234_567)
        let secret = try OpenAIRealtimeClientSecret(
            value: "  ephemeral-client-secret  ",
            expiresAt: expiresAt
        )

        #expect(secret.value == "  ephemeral-client-secret  ")
        #expect(secret.expiresAt == expiresAt)
    }

    @Test("rejects only an empty secret value with the typed error")
    func rejectsEmptyValue() {
        let expiresAt = Date(timeIntervalSince1970: 1_234_567)

        #expect(throws: OpenAIRealtimeClientSecretError.empty) {
            try OpenAIRealtimeClientSecret(value: "", expiresAt: expiresAt)
        }
    }

    @Test("whitespace remains a non-empty exact value")
    func preservesWhitespaceValue() throws {
        let secret = try OpenAIRealtimeClientSecret(
            value: "   ",
            expiresAt: Date(timeIntervalSince1970: 1_234_567)
        )

        #expect(secret.value == "   ")
    }

    @Test("client secret is Equatable and Sendable")
    func secretConformsToValueContracts() throws {
        let expiresAt = Date(timeIntervalSince1970: 1_234_567)
        let first = try OpenAIRealtimeClientSecret(value: "secret", expiresAt: expiresAt)
        let second = try OpenAIRealtimeClientSecret(value: "secret", expiresAt: expiresAt)

        #expect(first == second)
        acceptsSendable(first)
    }

    @Test("string diagnostics redact the credential value")
    func diagnosticsAreRedacted() throws {
        let token = "credential-that-must-not-appear"
        let secret = try OpenAIRealtimeClientSecret(
            value: token,
            expiresAt: Date(timeIntervalSince1970: 1_234_567)
        )

        #expect(!String(describing: secret).contains(token))
        #expect(!String(reflecting: secret).contains(token))
        #expect(String(reflecting: secret).contains("<redacted>"))

        var dumped = ""
        dump(secret, to: &dumped)
        #expect(!dumped.contains(token))
        #expect(dumped.contains("<redacted>"))
    }

    @Test("credential source receives the complete configuration")
    func sourceUsesConfigurationPort() async throws {
        let source = TestClientSecretSource()
        let configuration = OpenAIRealtimeConfiguration(
            model: "custom-model",
            voice: "custom-voice",
            instructions: "custom instructions"
        )

        let secret = try await source.clientSecret(for: configuration)

        #expect(secret.value == "source-secret")
        #expect(await source.receivedConfiguration == configuration)
    }
}

private actor TestClientSecretSource: OpenAIRealtimeClientSecretSource {
    private(set) var receivedConfiguration: OpenAIRealtimeConfiguration?

    func clientSecret(
        for configuration: OpenAIRealtimeConfiguration
    ) async throws -> OpenAIRealtimeClientSecret {
        receivedConfiguration = configuration
        return try OpenAIRealtimeClientSecret(
            value: "source-secret",
            expiresAt: Date(timeIntervalSince1970: 1_234_567)
        )
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
