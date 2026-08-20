/// Privacy-safe context used to choose the generic Phase 1 greeting.
///
/// Voice is currently limited to Taiwan Mandarin and the application does
/// not expose language selection or member details at this boundary.
public enum VoiceContext: Equatable, Sendable {
    case returningMember
    case visitor
}

/// Provider-neutral direction for one voice conversation.
///
/// The direction carries no member identity, profile, recognition confidence,
/// or exercise data. It only selects the conversation focus for the current
/// voice session.
public enum VoiceConversationDirection: Equatable, Sendable {
    case general
    case preWorkoutReminder
    case postWorkoutReview
}

/// Semantic lifecycle events emitted by a voice session.
///
/// Provider errors and payloads stay behind the Infrastructure adapter. The
/// coordinator uses `.failure` for generic retry behavior and
/// `.authorizationRequired` for device setup routing.
public enum VoiceSessionEvent: Equatable, Sendable {
    /// The user started speaking while the assistant was producing audio.
    ///
    /// Provider adapters emit this event instead of also emitting
    /// `userSpeechStarted` for the same interruption.
    case assistantInterrupted
    case userSpeechStarted
    case userSpeechEnded
    case responseReady
    case failure
    /// The current device credential must be provisioned again.
    case authorizationRequired
}

/// Semantic signal that the current device must be provisioned again.
public enum VoiceSessionAuthorizationError: Error, Equatable, Sendable {
    case authorizationRequired
}

/// Application boundary for a provider-independent voice session.
public protocol VoiceSessionPort: Sendable {
    /// Returns only after the voice session is ready for conversation.
    func start(context: VoiceContext) async throws

    /// Returns only after the voice session is ready for conversation, using
    /// the requested provider-neutral direction.
    func start(
        context: VoiceContext,
        direction: VoiceConversationDirection
    ) async throws

    /// Registers an independent subscriber for subsequent semantic events.
    func eventUpdates() async -> AsyncStream<VoiceSessionEvent>

    /// Ends the current voice session. Calling this repeatedly is safe.
    func stop() async
}

public extension VoiceSessionPort {
    /// Preserves the original start contract as the general direction.
    func start(
        context: VoiceContext,
        direction _: VoiceConversationDirection
    ) async throws {
        try await start(context: context)
    }
}
