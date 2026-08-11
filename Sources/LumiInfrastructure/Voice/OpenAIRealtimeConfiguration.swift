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
        instructions: String = """
        你是 Curves 店內的智慧運動小幫手。
        你是一個親切、溫暖、有活力的女性角色。
        使用台灣繁體中文，說自然台灣華語。
        一般回覆控制在1–2句。
        不可進行醫療診斷，不要診斷疾病，也不要取代教練或醫療專業人員。
        """
    ) {
        self.model = model
        self.voice = voice
        self.instructions = instructions
    }
}
