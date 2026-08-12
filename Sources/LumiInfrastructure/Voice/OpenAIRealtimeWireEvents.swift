import Foundation

/// Encodes the small set of client events used by the Phase 2.2 transport.
///
/// The data channel is ordered by the transport. These functions intentionally
/// return independent values so the caller decides when and whether to send an
/// initial `response.create`.
enum OpenAIRealtimeWireEncoder {
    static func sessionUpdate(
        for configuration: OpenAIRealtimeConfiguration
    ) throws -> Data {
        try encode([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": configuration.instructions,
                "audio": [
                    "input": [
                        "turn_detection": [
                            "type": "server_vad",
                            "create_response": true,
                            "interrupt_response": true,
                        ],
                    ],
                    "output": [
                        "voice": configuration.voice,
                    ],
                ],
            ],
        ])
    }

    static func responseCreate() throws -> Data {
        try encode(["type": "response.create"])
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// Decodes only provider events required by Lumi's voice-session boundary.
///
/// Returning `nil` means the provider event is intentionally ignored (for
/// example, a cancelled or completed response). No input payload is retained.
enum OpenAIRealtimeWireDecoder {
    static func decode(_ data: Data) -> OpenAIRealtimeProviderEvent? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data),
            let object = root as? [String: Any],
            let type = object["type"] as? String,
            !type.isEmpty
        else {
            return .error
        }

        switch type {
        case "session.created":
            return .sessionCreated
        case "input_audio_buffer.speech_started":
            return .inputAudioSpeechStarted
        case "input_audio_buffer.speech_stopped":
            return .inputAudioSpeechStopped
        case "output_audio_buffer.started":
            return .outputAudioStarted
        case "output_audio_buffer.stopped":
            return .outputAudioStopped
        case "output_audio_buffer.cleared":
            return .outputAudioCleared
        case "response.done":
            return responseDoneEvent(from: object)
        case "error":
            return .error
        default:
            return .unknown(type)
        }
    }

    private static func responseDoneEvent(
        from object: [String: Any]
    ) -> OpenAIRealtimeProviderEvent? {
        guard
            let response = object["response"] as? [String: Any],
            let status = response["status"] as? String
        else {
            return nil
        }

        switch status {
        case "failed", "incomplete":
            return .responseFailed
        case "cancelled", "completed":
            return nil
        default:
            return nil
        }
    }
}
