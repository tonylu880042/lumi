/// Provider configuration for a single OpenAI Realtime session.
///
/// The defaults are the Phase 2.1 product baseline. Callers may provide
/// explicit values when evaluating another model, voice, or prompt.
public struct OpenAIRealtimeConfiguration: Equatable, Sendable {
    public let model: String
    public let voice: String
    public let instructions: String

    /// Creates a Realtime configuration using Lumi's canonical defaults.
    public init(
        model: String = "gpt-realtime-2.1-mini",
        voice: String = "marin",
        instructions: String = OpenAIConversationPrompts.basePersona
    ) {
        self.model = model
        self.voice = voice
        self.instructions = instructions
    }
}
