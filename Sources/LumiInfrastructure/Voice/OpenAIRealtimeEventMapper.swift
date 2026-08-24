import LumiApplication

/// Provider events needed by the Realtime voice boundary.
///
/// The cases intentionally use provider-facing lifecycle names while keeping
/// provider payloads out of the Application port.
public enum OpenAIRealtimeProviderEvent: Equatable, Sendable {
    case sessionCreated
    case inputAudioSpeechStarted
    case inputAudioSpeechStopped
    case inputAudioCommitted(itemID: String)
    case outputAudioStarted
    case outputAudioStopped
    case outputAudioCleared
    case responseStarted
    case responseCompleted
    case responseFailed
    case toolCall(VoiceToolCall)
    case error
    case unknown(String)
}

/// A mapped event can either establish provider readiness or carry a
/// provider-independent voice lifecycle event.
enum OpenAIRealtimeMappedEvent: Equatable, Sendable {
    case ready
    case voice(VoiceSessionEvent)
}

/// Translates provider lifecycle events into Application voice events.
///
/// Realtime output state is kept here because interruption and first-playable
/// response readiness depend on the order of provider callbacks.
actor OpenAIRealtimeEventMapper {
    private var isOutputActive = false
    private var isResponseReadyArmed = false

    init() {}

    func map(
        _ event: OpenAIRealtimeProviderEvent
    ) -> [OpenAIRealtimeMappedEvent] {
        switch event {
        case .sessionCreated:
            return [.ready]

        case .inputAudioSpeechStarted:
            if isOutputActive {
                return [.voice(.assistantInterrupted)]
            }
            return [.voice(.userSpeechStarted)]

        case .inputAudioSpeechStopped:
            isResponseReadyArmed = true
            return [.voice(.userSpeechEnded)]

        case .inputAudioCommitted:
            return []

        case .outputAudioStarted:
            isOutputActive = true
            guard isResponseReadyArmed else { return [] }

            isResponseReadyArmed = false
            return [.voice(.responseReady)]

        case .outputAudioStopped, .outputAudioCleared:
            isOutputActive = false
            return []

        case .responseStarted, .responseCompleted:
            return []

        case .responseFailed, .error:
            return [.voice(.failure)]

        case .toolCall:
            return []

        case .unknown:
            return []
        }
    }
}
