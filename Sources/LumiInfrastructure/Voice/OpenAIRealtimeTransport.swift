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

    /// Connects with the bounded member-memory disclosure tool capability.
    func connect(
        clientSecret: OpenAIRealtimeClientSecret,
        configuration: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose,
        enablesWeeklySummaryTool: Bool,
        enablesVisitorEnrollmentTools: Bool,
        enablesMemberMemoryTool: Bool
    ) async throws

    /// Promotes a connected standby transport into the active conversation.
    /// The concrete transport owns permission/media activation and sends the
    /// final session configuration followed by exactly one greeting. This
    /// four-argument requirement is the canonical witness so a memory-tool
    /// capability cannot be lost through protocol-extension dispatch.
    func activate(
        configuration: OpenAIRealtimeConfiguration,
        enablesWeeklySummaryTool: Bool,
        enablesVisitorEnrollmentTools: Bool,
        enablesMemberMemoryTool: Bool
    ) async throws

    /// Enables or disables conversation media after a local opening has
    /// completed. Concrete WebRTC transports use this to keep the microphone
    /// track disabled while a prerecorded clip is playing.
    func setConversationMediaEnabled(_ enabled: Bool) async throws

    /// Returns the provider event stream for this transport instance.
    ///
    /// The stream finishes when the underlying connection closes. The adapter
    /// distinguishes its own clean `stop()` from an unexpected termination.
    func eventUpdates() async -> AsyncStream<OpenAIRealtimeProviderEvent>

    /// Returns the per-response usage stream for this transport instance.
    ///
    /// This exists solely for the one-off Realtime cost-telemetry milestone
    /// and is independent of `eventUpdates()`. A transport that never yields
    /// usage (for example a test double) simply never sends a value; the
    /// default implementation below returns an already-finished stream.
    func usageUpdates() async -> AsyncStream<OpenAIRealtimeResponseUsage>

    /// Cleanly closes the underlying WebRTC connection.
    func close() async

    /// Sends one already-encoded client event over the active data channel.
    func send(_ data: Data) async throws
}

public extension OpenAIRealtimeTransport {
    func activate(
        configuration: OpenAIRealtimeConfiguration,
        enablesWeeklySummaryTool: Bool,
        enablesVisitorEnrollmentTools: Bool
    ) async throws {
        try await activate(
            configuration: configuration,
            enablesWeeklySummaryTool: enablesWeeklySummaryTool,
            enablesVisitorEnrollmentTools: enablesVisitorEnrollmentTools,
            enablesMemberMemoryTool: false
        )
    }

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

    func connect(
        clientSecret: OpenAIRealtimeClientSecret,
        configuration: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose,
        enablesWeeklySummaryTool: Bool,
        enablesVisitorEnrollmentTools: Bool,
        enablesMemberMemoryTool _: Bool
    ) async throws {
        try await connect(
            clientSecret: clientSecret,
            configuration: configuration,
            purpose: purpose,
            enablesWeeklySummaryTool: enablesWeeklySummaryTool,
            enablesVisitorEnrollmentTools: enablesVisitorEnrollmentTools
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

    func usageUpdates() async -> AsyncStream<OpenAIRealtimeResponseUsage> {
        AsyncStream { continuation in continuation.finish() }
    }

    /// Existing deterministic transports remain valid when they do not model
    /// the optional local-greeting media gate.
    func setConversationMediaEnabled(_: Bool) async throws {}

}

/// Creates one fresh transport for every initial connection or retry.
public protocol OpenAIRealtimeTransportFactory: Sendable {
    func makeTransport() async -> any OpenAIRealtimeTransport
}
