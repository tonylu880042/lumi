import Foundation
import LumiApplication
import LumiDomain

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
        enablesWeeklySummaryTool: Bool = false,
        enablesVisitorEnrollmentTools: Bool = false,
        enablesMemberMemoryTool: Bool = false
    ) throws -> Data {
        var session: [String: Any] = [
            "type": "realtime",
            "instructions": configuration.instructions,
            // A tunable cap, not a magic number — see the property's doc
            // comment on `OpenAIRealtimeConfiguration` for the trade-off.
            "max_output_tokens": configuration.maxResponseOutputTokens,
            "audio": [
                "input": [
                    "turn_detection": [
                        "type": "server_vad",
                        // Lumi confirms near-end speech locally before it
                        // cancels output or creates the next response.
                        "create_response": false,
                        "interrupt_response": false,
                        "threshold": 0.625,
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": 800,
                    ],
                ],
                "output": [
                    "voice": configuration.voice,
                ],
            ],
        ]

        var tools: [[String: Any]] = []
        if enablesWeeklySummaryTool {
            tools.append([
                "type": "function",
                "name": "get_member_weekly_summary",
                "description": "Return the member's weekly exercise summary.",
                "parameters": [
                    "type": "object",
                    "properties": [String: Any](),
                    "required": [String](),
                    "additionalProperties": false,
                ],
            ])
        }
        if enablesMemberMemoryTool {
            tools.append([
                "type": "function",
                "name": "record_member_exercise_disclosure",
                "description": "Record the known member's explicit current exercise state.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "disclosure": [
                            "type": "string",
                            "enum": ["preparing", "just_completed", "completed_today"],
                        ],
                    ],
                    "required": ["disclosure"],
                    "additionalProperties": false,
                ],
            ])
            tools.append([
                "type": "function",
                "name": "correct_member_exercise_disclosure",
                "description": "Correct or retract the known member's current exercise disclosure.",
                "parameters": [
                    "type": "object",
                    "properties": [String: Any](),
                    "required": [String](),
                    "additionalProperties": false,
                ],
            ])
        }
        if enablesVisitorEnrollmentTools {
            tools.append(contentsOf: [
                [
                    "type": "function",
                    "name": "begin_visitor_enrollment",
                    "description": "Capture exactly three face enrollment samples after the visitor clearly consents.",
                    "parameters": [
                        "type": "object",
                        "properties": [String: Any](),
                        "required": [String](),
                        "additionalProperties": false,
                    ],
                ],
                [
                    "type": "function",
                    "name": "complete_visitor_enrollment",
                    "description": "Commit the pending face enrollment after the visitor states how Lumi should address them.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "spoken_label": [
                                "type": "string",
                                "description": "The visitor's spoken preferred name or form of address.",
                            ],
                        ],
                        "required": ["spoken_label"],
                        "additionalProperties": false,
                    ],
                ],
            ])
        }
        if configuration.allowsConversationClosing {
            tools.append([
                "type": "function",
                "name": "end_conversation",
                "description": "End the current short conversation after the visitor clearly says goodbye.",
                "parameters": [
                    "type": "object",
                    "properties": [String: Any](),
                    "required": [String](),
                    "additionalProperties": false,
                ],
            ])
        }
        if !tools.isEmpty {
            session["tools"] = tools
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

    static func responseCancel() throws -> Data {
        try encode(["type": "response.cancel"])
    }

    static func outputAudioBufferClear() throws -> Data {
        try encode(["type": "output_audio_buffer.clear"])
    }

    static func conversationItemDelete(itemID: String) throws -> Data {
        try encode([
            "type": "conversation.item.delete",
            "item_id": itemID,
        ])
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
        case "input_audio_buffer.committed":
            guard let itemID = object["item_id"] as? String,
                  !itemID.isEmpty else {
                return .error
            }
            return .inputAudioCommitted(itemID: itemID)
        case "output_audio_buffer.started":
            return .outputAudioStarted
        case "output_audio_buffer.stopped":
            return .outputAudioStopped
        case "output_audio_buffer.cleared":
            return .outputAudioCleared
        case "response.created":
            return .responseStarted
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
            return .responseCompleted
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

        guard [
            "get_member_weekly_summary",
            "record_member_exercise_disclosure",
            "correct_member_exercise_disclosure",
            "begin_visitor_enrollment",
            "complete_visitor_enrollment",
            "end_conversation",
        ].contains(name) else {
            return .toolCall(
                VoiceToolCall(callID: callID, kind: .unsupported)
            )
        }

        guard
            let arguments = object["arguments"] as? String,
            let argumentsData = arguments.data(using: .utf8),
            let parsedArguments = try? JSONSerialization.jsonObject(with: argumentsData),
            let argumentsObject = parsedArguments as? [String: Any]
        else {
            return .toolCall(
                VoiceToolCall(callID: callID, kind: .invalidArguments)
            )
        }

        let kind: VoiceToolCallKind
        switch name {
        case "get_member_weekly_summary":
            guard argumentsObject.isEmpty else {
                return invalidToolArguments(callID: callID)
            }
            kind = .getMemberWeeklySummary
        case "record_member_exercise_disclosure":
            guard
                Set(argumentsObject.keys) == ["disclosure"],
                let value = argumentsObject["disclosure"] as? String,
                let disclosure = memberExerciseDisclosure(for: value)
            else {
                return invalidToolArguments(callID: callID)
            }
            kind = .recordExerciseDisclosure(disclosure)
        case "correct_member_exercise_disclosure":
            guard argumentsObject.isEmpty else {
                return invalidToolArguments(callID: callID)
            }
            kind = .correctMemberExerciseDisclosure
        case "begin_visitor_enrollment":
            guard argumentsObject.isEmpty else {
                return invalidToolArguments(callID: callID)
            }
            kind = .beginVisitorEnrollment
        case "complete_visitor_enrollment":
            guard
                Set(argumentsObject.keys) == ["spoken_label"],
                let spokenLabel = argumentsObject["spoken_label"] as? String,
                let address = try? VoiceMemberAddress(spokenLabel: spokenLabel)
            else {
                return invalidToolArguments(callID: callID)
            }
            kind = .completeVisitorEnrollment(address)
        case "end_conversation":
            guard argumentsObject.isEmpty else {
                return invalidToolArguments(callID: callID)
            }
            kind = .endConversation
        default:
            preconditionFailure("Supported tool name guard is exhaustive")
        }

        return .toolCall(VoiceToolCall(callID: callID, kind: kind))
    }

    private static func invalidToolArguments(
        callID: String
    ) -> OpenAIRealtimeProviderEvent {
        .toolCall(VoiceToolCall(callID: callID, kind: .invalidArguments))
    }

    private static func memberExerciseDisclosure(
        for value: String
    ) -> MemberExerciseDisclosure? {
        switch value {
        case "preparing":
            .preparing
        case "just_completed":
            .justCompleted
        case "completed_today":
            .completedToday
        default:
            nil
        }
    }
}

/// Integer-only token counters copied from one `response.done` payload.
///
/// This exists solely for the one-off Realtime cost-telemetry milestone (see
/// the greeting on-device cost question). Every field is a non-negative
/// token count; no transcript, audio, identifier, or other free-form value
/// is ever carried here.
public struct OpenAIRealtimeResponseUsage: Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let cachedInputTokens: Int
    public let inputTextTokens: Int
    public let inputAudioTokens: Int
    public let outputTextTokens: Int
    public let outputAudioTokens: Int

    public init(
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        cachedInputTokens: Int,
        inputTextTokens: Int,
        inputAudioTokens: Int,
        outputTextTokens: Int,
        outputAudioTokens: Int
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens
        self.inputTextTokens = inputTextTokens
        self.inputAudioTokens = inputAudioTokens
        self.outputTextTokens = outputTextTokens
        self.outputAudioTokens = outputAudioTokens
    }
}

extension OpenAIRealtimeWireDecoder {
    /// Independently parses the integer `response.usage` counters from a raw
    /// `response.done` payload.
    ///
    /// This is deliberately decoded separately from `decode(_:)` /
    /// `responseDoneEvent(from:)` so a missing or malformed usage field can
    /// never change the existing status-driven event mapping. Any absent or
    /// non-numeric field safely degrades to `0`; this function never throws
    /// and returns `nil` only when the payload is not a `response.done`
    /// event carrying a `response.usage` object at all.
    static func responseUsage(from data: Data) -> OpenAIRealtimeResponseUsage? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data),
            let object = root as? [String: Any],
            object["type"] as? String == "response.done",
            let response = object["response"] as? [String: Any],
            let usage = response["usage"] as? [String: Any]
        else {
            return nil
        }

        let inputDetails = usage["input_token_details"] as? [String: Any] ?? [:]
        let outputDetails = usage["output_token_details"] as? [String: Any] ?? [:]

        return OpenAIRealtimeResponseUsage(
            inputTokens: nonNegativeInt("input_tokens", in: usage),
            outputTokens: nonNegativeInt("output_tokens", in: usage),
            totalTokens: nonNegativeInt("total_tokens", in: usage),
            cachedInputTokens: nonNegativeInt("cached_tokens", in: inputDetails),
            inputTextTokens: nonNegativeInt("text_tokens", in: inputDetails),
            inputAudioTokens: nonNegativeInt("audio_tokens", in: inputDetails),
            outputTextTokens: nonNegativeInt("text_tokens", in: outputDetails),
            outputAudioTokens: nonNegativeInt("audio_tokens", in: outputDetails)
        )
    }

    private static func nonNegativeInt(
        _ key: String,
        in dictionary: [String: Any]
    ) -> Int {
        guard
            let number = dictionary[key] as? NSNumber,
            !(dictionary[key] is Bool)
        else {
            return 0
        }
        return max(0, number.intValue)
    }
}
