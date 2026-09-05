import Foundation

/// A provider-specific seam for the WebRTC Realtime transport.
///
/// A concrete WebRTC implementation belongs in Infrastructure and is injected
/// through this protocol. The adapter only owns session lifecycle; it never
/// constructs a network client or an audio engine itself.
public enum OpenAIRealtimeConnectionPurpose: Equatable, Sendable {
    case initial
    case reconnect
    case standby
}

public protocol OpenAIRealtimeTransport: Sendable {
    /// Connects this fresh transport using one short-lived client credential.
    func connect(
        clientSecret: OpenAIRealtimeClientSecret,
        configuration: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose,
        enablesWeeklySummaryTool: Bool
    ) async throws

    /// Connects with the exact provider-neutral tool capabilities approved for
    /// this session context.
    func connect(
        clientSecret: OpenAIRealtimeClientSecret,
        configuration: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose,
        enablesWeeklySummaryTool: Bool,
        enablesVisitorEnrollmentTools: Bool
    ) async throws

    /// Returns the provider event stream for this transport instance.
    ///
    /// The stream finishes when the underlying connection closes. The adapter
    /// distinguishes its own clean `stop()` from an unexpected termination.
    func eventUpdates() async -> AsyncStream<OpenAIRealtimeProviderEvent>

    /// Cleanly closes the underlying WebRTC connection.
    func close() async

    /// Sends one already-encoded client event over the active data channel.
    func send(_ data: Data) async throws
}

public extension OpenAIRealtimeTransport {
    func connect(
        clientSecret: OpenAIRealtimeClientSecret,
        configuration: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose,
        enablesWeeklySummaryTool: Bool,
        enablesVisitorEnrollmentTools _: Bool
    ) async throws {
        try await connect(
            clientSecret: clientSecret,
            configuration: configuration,
            purpose: purpose,
            enablesWeeklySummaryTool: enablesWeeklySummaryTool
        )
    }

    /// Connects without enabling application tools.
    func connect(
        clientSecret: OpenAIRealtimeClientSecret,
        configuration: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose
    ) async throws {
        try await connect(
            clientSecret: clientSecret,
            configuration: configuration,
            purpose: purpose,
            enablesWeeklySummaryTool: false
        )
    }
}

/// Creates one fresh transport for every initial connection or retry.
public protocol OpenAIRealtimeTransportFactory: Sendable {
    func makeTransport() async -> any OpenAIRealtimeTransport
}
