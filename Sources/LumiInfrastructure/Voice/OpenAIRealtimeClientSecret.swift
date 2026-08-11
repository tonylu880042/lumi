import Foundation

/// A short-lived credential issued for one OpenAI Realtime client session.
public struct OpenAIRealtimeClientSecret:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    private let secretValue: String

    /// Exact short-lived token passed only to the injected transport.
    public var value: String { secretValue }
    public let expiresAt: Date

    /// Creates a credential while preserving its exact value.
    public init(
        value: String,
        expiresAt: Date
    ) throws(OpenAIRealtimeClientSecretError) {
        guard !value.isEmpty else {
            throw OpenAIRealtimeClientSecretError.empty
        }

        self.secretValue = value
        self.expiresAt = expiresAt
    }

    /// Redacts the token from ordinary diagnostics.
    public var description: String {
        "OpenAIRealtimeClientSecret(value: <redacted>, expiresAt: \(expiresAt))"
    }

    /// Redacts the token from reflective string diagnostics.
    public var debugDescription: String { description }

    /// Redacts the token from `Mirror`-based diagnostics such as `dump`.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["value": "<redacted>", "expiresAt": expiresAt],
            displayStyle: .struct
        )
    }
}

/// Validation failures for an OpenAI Realtime client secret.
public enum OpenAIRealtimeClientSecretError: Error, Equatable, Sendable {
    case empty
}

/// Supplies a short-lived credential without exposing the standard API key.
public protocol OpenAIRealtimeClientSecretSource: Sendable {
    /// Fetches a short-lived secret for the complete provider session setup.
    func clientSecret(
        for configuration: OpenAIRealtimeConfiguration
    ) async throws -> OpenAIRealtimeClientSecret
}
