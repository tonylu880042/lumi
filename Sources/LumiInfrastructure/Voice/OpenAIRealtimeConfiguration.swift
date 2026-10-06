/// Provider configuration for a single OpenAI Realtime session.
///
/// The defaults are the Phase 2.1 product baseline. Callers may provide
/// explicit values when evaluating another model, voice, or prompt.
public struct OpenAIRealtimeConfiguration: Equatable, Sendable {
    public let model: String
    public let voice: String
    public let instructions: String

    /// Upper bound on `response.output` tokens per turn, sent to the
    /// provider as `max_output_tokens`.
    ///
    /// This is a tunable knob, not a constant — it needs real on-device
    /// measurement, not a guess. `OpenAIConversationPrompts` explicitly asks
    /// for privacy/consent explanations to state their point in full rather
    /// than being shortened for length (see e.g. the visitor-enrollment
    /// consent prompt); a cap set too low would truncate exactly that kind
    /// of explanation mid-sentence. 1024 is a starting default, kept
    /// generous on purpose until real usage data says otherwise.
    public let maxResponseOutputTokens: Int

    /// When true, Lumi supplies the opening greeting through its local
    /// prerecorded voice adapter. Realtime must configure the session but must
    /// not create an opening response of its own.
    public let usesExternalGreeting: Bool

    /// When enabled by the Live composition, the provider may request a
    /// contextual conversational closing. Infrastructure only accepts that
    /// request after an actual post-greeting user turn and completes it with
    /// the injected local farewell player.
    public let allowsConversationClosing: Bool

    /// Creates a Realtime configuration using Lumi's canonical defaults.
    public init(
        model: String = "gpt-realtime-2.1-mini",
        voice: String = "marin",
        instructions: String = OpenAIConversationPrompts.basePersona,
        maxResponseOutputTokens: Int = 1024,
        usesExternalGreeting: Bool = false,
        allowsConversationClosing: Bool = false
    ) {
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.maxResponseOutputTokens = maxResponseOutputTokens
        self.usesExternalGreeting = usesExternalGreeting
        self.allowsConversationClosing = allowsConversationClosing
    }
}
