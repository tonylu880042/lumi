import Foundation
import LumiApplication

/// Encodes the small set of client events used by the Phase 2.2 transport.
///
/// The data channel is ordered by the transport. These functions intentionally
/// return independent values so the caller decides when and whether to send an
/// initial `response.create`.
enum OpenAIRealtimeWireEncoder {
    // OpenAI Realtime function-calling event shapes:
    // https://developers.openai.com/api/docs/guides/realtime-mcp
    static func sessionUpdate(
        for configuration: OpenAIRealtimeConfiguration,
        enablesWeeklySummaryTool: Bool = false
    ) throws -> Data {
        var session: [String: Any] = [
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
        ]

        if enablesWeeklySummaryTool {
            session["tools"] = [[
                "type": "function",
                "name": "get_member_weekly_summary",
                "description": "Return the member's weekly exercise summary.",
                "parameters": [
                    "type": "object",
                    "properties": [String: Any](),
                    "required": [String](),
                    "additionalProperties": false,
                ],
            ]]
            session["tool_choice"] = "auto"
        }

        return try encode([
            "type": "session.update",
            "session": session,
        ])
    }

    static func functionCallOutput(for result: VoiceToolResult) throws -> Data {
        let output = String(decoding: result.jsonData(), as: UTF8.self)
        return try encode([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": result.callID,
                "output": output,
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
        case "response.function_call_arguments.done":
            return functionCallArgumentsDoneEvent(from: object)
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

    private static func functionCallArgumentsDoneEvent(
        from object: [String: Any]
    ) -> OpenAIRealtimeProviderEvent? {
        guard
            let callID = object["call_id"] as? String,
            !callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        guard
            let name = object["name"] as? String,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .toolCall(
                VoiceToolCall(callID: callID, kind: .invalidArguments)
            )
        }

        guard name == "get_member_weekly_summary" else {
            return .toolCall(
                VoiceToolCall(callID: callID, kind: .unsupported)
            )
        }

        guard
            let arguments = object["arguments"] as? String,
            let argumentsData = arguments.data(using: .utf8),
            let parsedArguments = try? JSONSerialization.jsonObject(with: argumentsData),
            let argumentsObject = parsedArguments as? [String: Any],
            argumentsObject.isEmpty
        else {
            return .toolCall(
                VoiceToolCall(callID: callID, kind: .invalidArguments)
            )
        }

        return .toolCall(
            VoiceToolCall(callID: callID, kind: .getMemberWeeklySummary)
        )
    }
}
