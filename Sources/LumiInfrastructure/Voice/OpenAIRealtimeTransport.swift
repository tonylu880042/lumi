/// A provider-specific seam for the WebRTC Realtime transport.
///
/// A concrete WebRTC implementation belongs in Infrastructure and is injected
/// through this protocol. The adapter only owns session lifecycle; it never
/// constructs a network client or an audio engine itself.
public protocol OpenAIRealtimeTransport: Sendable {
    /// Connects this fresh transport using one short-lived client credential.
    func connect(
        clientSecret: OpenAIRealtimeClientSecret,
        configuration: OpenAIRealtimeConfiguration
    ) async throws

    /// Returns the provider event stream for this transport instance.
    ///
    /// The stream finishes when the underlying connection closes. The adapter
    /// distinguishes its own clean `stop()` from an unexpected termination.
    func eventUpdates() async -> AsyncStream<OpenAIRealtimeProviderEvent>

    /// Cleanly closes the underlying WebRTC connection.
    func close() async
}

/// Creates one fresh transport for every initial connection or retry.
public protocol OpenAIRealtimeTransportFactory: Sendable {
    func makeTransport() async -> any OpenAIRealtimeTransport
}
