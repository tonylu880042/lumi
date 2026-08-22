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

/// A deliberately narrow, provider-neutral label that voice may speak.
///
/// This value is not a member profile and carries no exercise, recognition,
/// or biometric data. Its restricted alphabet keeps an enrollment identifier
/// from becoming free-form prompt text at the provider boundary.
public struct VoiceMemberAddress: Equatable, Sendable {
    public let spokenLabel: String

    public init(spokenLabel: String) throws(VoiceMemberAddressError) {
        guard
            !spokenLabel.isEmpty,
            spokenLabel.count <= 32,
            spokenLabel.allSatisfy({ character in
                character.isLetter
                    || character.isNumber
            })
        else {
            throw VoiceMemberAddressError.invalid
        }

        self.spokenLabel = spokenLabel
    }
}

/// Fixed, payload-free validation failure for a spoken member label.
public enum VoiceMemberAddressError: Error, Equatable, Sendable {
    case invalid
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

    /// Returns only after the voice session is ready, optionally allowing a
    /// previously validated address label for a confirmed returning member.
    func start(
        context: VoiceContext,
        direction: VoiceConversationDirection,
        memberAddress: VoiceMemberAddress?
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

    /// Existing ports remain anonymous until their composition explicitly
    /// opts into the narrow member-address contract.
    func start(
        context: VoiceContext,
        direction: VoiceConversationDirection,
        memberAddress _: VoiceMemberAddress?
    ) async throws {
        try await start(context: context, direction: direction)
    }
}
