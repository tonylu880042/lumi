import Foundation
import LumiApplication
@testable import LumiInfrastructure
import Testing

@Suite("OpenAI Realtime wire events")
struct OpenAIRealtimeWireEventsTests {
    @Test("session.update carries the approved session configuration")
    func sessionUpdateUsesCurrentRealtimeShape() throws {
        let configuration = OpenAIRealtimeConfiguration(
            model: "model-is-selected-by-signaling",
            voice: "marin",
            instructions: "Use concise Taiwan Traditional Chinese."
        )

        let root = try jsonObject(
            try OpenAIRealtimeWireEncoder.sessionUpdate(for: configuration)
        )
        #expect(root["type"] as? String == "session.update")

        let session = try object(root, at: "session")
        #expect(session["type"] as? String == "realtime")
        #expect(session["instructions"] as? String == configuration.instructions)

        let audio = try object(session, at: "audio")
        let input = try object(audio, at: "input")
        let turnDetection = try object(input, at: "turn_detection")
        #expect(turnDetection["type"] as? String == "server_vad")
        #expect(turnDetection["create_response"] as? Bool == false)
        #expect(turnDetection["interrupt_response"] as? Bool == false)

        let output = try object(audio, at: "output")
        #expect(output["voice"] as? String == configuration.voice)
        #expect(session["voice"] == nil)

        // Tuned from physical-device evidence to prevent premature turn-taking
        // and reject ambient room noise in gym environment.
        #expect(turnDetection["threshold"] as? Double == 0.625)
        #expect(turnDetection["prefix_padding_ms"] as? Int == 300)
        #expect(turnDetection["silence_duration_ms"] as? Int == 800)
    }

    @Test("session.update default keeps the existing no-tools JSON behavior")
    func sessionUpdateDefaultsToNoTools() throws {
        let configuration = OpenAIRealtimeConfiguration(
            voice: "marin",
            instructions: "instructions"
        )

        let defaultData = try OpenAIRealtimeWireEncoder.sessionUpdate(
            for: configuration
        )
        let explicitlyDisabledData = try OpenAIRealtimeWireEncoder.sessionUpdate(
            for: configuration,
            enablesWeeklySummaryTool: false
        )
        let session = try object(
            try jsonObject(defaultData),
            at: "session"
        )

        #expect(defaultData == explicitlyDisabledData)
        #expect(
            String(data: defaultData, encoding: .utf8)
                == #"{"session":{"audio":{"input":{"turn_detection":{"create_response":false,"interrupt_response":false,"prefix_padding_ms":300,"silence_duration_ms":800,"threshold":0.625,"type":"server_vad"}},"output":{"voice":"marin"}},"instructions":"instructions","type":"realtime"},"type":"session.update"}"#
        )
        #expect(session["tools"] == nil)
        #expect(session["tool_choice"] == nil)
    }

    @Test("enabled session.update carries exactly one empty-argument weekly tool")
    func sessionUpdateDeclaresOnlyWeeklySummaryTool() throws {
        let configuration = OpenAIRealtimeConfiguration(
            voice: "marin",
            instructions: "instructions"
        )

        let root = try jsonObject(
            try OpenAIRealtimeWireEncoder.sessionUpdate(
                for: configuration,
                enablesWeeklySummaryTool: true
            )
        )
        let session = try object(root, at: "session")
        guard let tools = session["tools"] as? [[String: Any]], tools.count == 1 else {
            Issue.record("Expected one weekly summary function tool")
            return
        }
        let tool = tools[0]
        let parameters = try object(tool, at: "parameters")
        guard let properties = parameters["properties"] as? [String: Any] else {
            Issue.record("Expected an object-valued empty properties schema")
            return
        }
        guard let required = parameters["required"] as? [Any] else {
            Issue.record("Expected an array-valued empty required schema")
            return
        }

        #expect(tool["type"] as? String == "function")
        #expect(tool["name"] as? String == "get_member_weekly_summary")
        #expect(tool["description"] as? String == "Return the member's weekly exercise summary.")
        #expect(parameters["type"] as? String == "object")
        #expect(properties.isEmpty)
        #expect(required.isEmpty)
        #expect(parameters["additionalProperties"] as? Bool == false)
        #expect(session["tool_choice"] as? String == "auto")

        let serialized = String(
            data: try OpenAIRealtimeWireEncoder.sessionUpdate(
                for: configuration,
                enablesWeeklySummaryTool: true
            ),
            encoding: .utf8
        )
        #expect(serialized?.contains("member_id") == false)
    }

    @Test("visitor enrollment session declares only consent and naming tools")
    func sessionUpdateDeclaresVisitorEnrollmentTools() throws {
        let configuration = OpenAIRealtimeConfiguration(
            voice: "marin",
            instructions: "instructions"
        )

        let root = try jsonObject(
            try OpenAIRealtimeWireEncoder.sessionUpdate(
                for: configuration,
                enablesVisitorEnrollmentTools: true
            )
        )
        let session = try object(root, at: "session")
        guard let tools = session["tools"] as? [[String: Any]] else {
            Issue.record("Expected visitor enrollment tools")
            return
        }

        #expect(tools.count == 2)
        #expect(tools.compactMap { $0["name"] as? String } == [
            "begin_visitor_enrollment",
            "complete_visitor_enrollment",
        ])

        let beginParameters = try object(tools[0], at: "parameters")
        #expect((beginParameters["properties"] as? [String: Any])?.isEmpty == true)
        #expect((beginParameters["required"] as? [Any])?.isEmpty == true)
        #expect(beginParameters["additionalProperties"] as? Bool == false)

        let completeParameters = try object(tools[1], at: "parameters")
        let completeProperties = try object(completeParameters, at: "properties")
        let spokenLabel = try object(completeProperties, at: "spoken_label")
        #expect(spokenLabel["type"] as? String == "string")
        #expect(completeParameters["required"] as? [String] == ["spoken_label"])
        #expect(completeParameters["additionalProperties"] as? Bool == false)
        #expect(session["tool_choice"] as? String == "auto")
    }

    @Test("response.create is the minimal event and caller can preserve order")
    func responseCreateCanFollowSessionUpdate() throws {
        let configuration = OpenAIRealtimeConfiguration(
            voice: "marin",
            instructions: "instructions"
        )
        let events = [
            try jsonObject(try OpenAIRealtimeWireEncoder.sessionUpdate(for: configuration)),
            try jsonObject(try OpenAIRealtimeWireEncoder.responseCreate()),
        ]

        #expect(events.map { $0["type"] as? String } == [
            "session.update",
            "response.create",
        ])
        #expect(events[1].count == 1)
    }

    @Test("confirmed WebRTC barge-in has ordered cancel and playout clear events")
    func confirmedBargeInEventsAreMinimal() throws {
        let events = [
            try jsonObject(try OpenAIRealtimeWireEncoder.responseCancel()),
            try jsonObject(try OpenAIRealtimeWireEncoder.outputAudioBufferClear()),
        ]

        #expect(events.map { $0["type"] as? String } == [
            "response.cancel",
            "output_audio_buffer.clear",
        ])
        #expect(events.allSatisfy { $0.count == 1 })
    }

    @Test("rejected echo input can be removed by opaque committed item ID")
    func rejectedInputDeleteUsesOnlyOpaqueItemID() throws {
        let event = try jsonObject(
            try OpenAIRealtimeWireEncoder.conversationItemDelete(
                itemID: "opaque-input-item"
            )
        )

        #expect(event["type"] as? String == "conversation.item.delete")
        #expect(event["item_id"] as? String == "opaque-input-item")
        #expect(event.keys.sorted() == ["item_id", "type"])
    }

    @Test("function call output encodes exact result JSON and opaque call ID")
    func functionCallOutputUsesExactResultPayload() throws {
        let result = VoiceToolResult(
            callID: "  opaque-call-id  ",
            payload: .failure(.invalidArguments)
        )

        let data = try OpenAIRealtimeWireEncoder.functionCallOutput(for: result)
        let root = try jsonObject(data)
        let item = try object(root, at: "item")

        #expect(root.keys.sorted() == ["item", "type"])
        #expect(root["type"] as? String == "conversation.item.create")
        #expect(item.keys.sorted() == ["call_id", "output", "type"])
        #expect(item["type"] as? String == "function_call_output")
        #expect(item["call_id"] as? String == result.callID)
        #expect(item["output"] as? String == #"{"error":"invalid_arguments"}"#)

        let serialized = String(data: data, encoding: .utf8) ?? ""
        #expect(
            serialized
                == #"{"item":{"call_id":"  opaque-call-id  ","output":"{\"error\":\"invalid_arguments\"}","type":"function_call_output"},"type":"conversation.item.create"}"#
        )
        #expect(serialized.contains("member_id") == false)
        #expect(serialized.contains("raw-provider-arguments") == false)
        #expect(serialized.contains("get_member_weekly_summary") == false)
    }

    @Test("approved server events map to provider lifecycle events")
    func approvedEventsDecode() throws {
        let fixtures: [(String, OpenAIRealtimeProviderEvent)] = [
            ("session.created", .sessionCreated),
            ("input_audio_buffer.speech_started", .inputAudioSpeechStarted),
            ("input_audio_buffer.speech_stopped", .inputAudioSpeechStopped),
            ("output_audio_buffer.started", .outputAudioStarted),
            ("output_audio_buffer.stopped", .outputAudioStopped),
            ("output_audio_buffer.cleared", .outputAudioCleared),
            ("error", .error),
        ]

        for (type, expected) in fixtures {
            let decoded = OpenAIRealtimeWireDecoder.decode(
                try jsonData(["type": type])
            )
            #expect(decoded == expected)
        }
    }

    @Test("committed input keeps only the opaque item ID inside Infrastructure")
    func committedInputDecodesOpaqueItemID() throws {
        let decoded = OpenAIRealtimeWireDecoder.decode(
            try jsonData([
                "type": "input_audio_buffer.committed",
                "item_id": "opaque-input-item",
                "previous_item_id": "ignored-provider-metadata",
            ])
        )

        #expect(decoded == .inputAudioCommitted(itemID: "opaque-input-item"))
        #expect(OpenAIRealtimeWireDecoder.decode(
            try jsonData([
                "type": "input_audio_buffer.committed",
                "item_id": "",
            ])
        ) == .error)
    }

    @Test("response lifecycle distinguishes active completion from failures")
    func responseLifecycleStatusesDecode() throws {
        let started = OpenAIRealtimeWireDecoder.decode(
            try jsonData(["type": "response.created"])
        )
        let failed = OpenAIRealtimeWireDecoder.decode(
            try jsonData([
                "type": "response.done",
                "response": ["status": "failed", "secret": "do-not-retain"],
            ])
        )
        let incomplete = OpenAIRealtimeWireDecoder.decode(
            try jsonData([
                "type": "response.done",
                "response": ["status": "incomplete"],
            ])
        )
        let cancelled = OpenAIRealtimeWireDecoder.decode(
            try jsonData([
                "type": "response.done",
                "response": ["status": "cancelled"],
            ])
        )
        let completed = OpenAIRealtimeWireDecoder.decode(
            try jsonData([
                "type": "response.done",
                "response": ["status": "completed"],
            ])
        )

        #expect(started == .responseStarted)
        #expect(failed == .responseFailed)
        #expect(incomplete == .responseFailed)
        #expect(cancelled == .responseCompleted)
        #expect(completed == .responseCompleted)
    }

    @Test("finalized function calls map only exact empty arguments")
    func finalizedFunctionCallArgumentsDecodeMatrix() throws {
        let preservedCallID = "  opaque-call-id  "
        let valid = OpenAIRealtimeWireDecoder.decode(
            try jsonData([
                "type": "response.function_call_arguments.done",
                "call_id": preservedCallID,
                "name": "get_member_weekly_summary",
                "arguments": "{}",
            ])
        )
        #expect(
            valid == .toolCall(
                VoiceToolCall(
                    callID: preservedCallID,
                    kind: .getMemberWeeklySummary
                )
            )
        )

        for (index, arguments) in ["{ }", "\n { \n } \t"].enumerated() {
            let formattedEmptyObject = OpenAIRealtimeWireDecoder.decode(
                try jsonData([
                    "type": "response.function_call_arguments.done",
                    "call_id": "formatted-empty-arguments-\(index)",
                    "name": "get_member_weekly_summary",
                    "arguments": arguments,
                ])
            )
            #expect(
                formattedEmptyObject == .toolCall(
                    VoiceToolCall(
                        callID: "formatted-empty-arguments-\(index)",
                        kind: .getMemberWeeklySummary
                    )
                )
            )
        }

        let unsupported = OpenAIRealtimeWireDecoder.decode(
            try jsonData([
                "type": "response.function_call_arguments.done",
                "call_id": "unsupported-call",
                "name": "other_tool",
                "arguments": "not-json",
            ])
        )
        #expect(
            unsupported == .toolCall(
                VoiceToolCall(callID: "unsupported-call", kind: .unsupported)
            )
        )

        let invalidArguments: [[String: Any]] = [
            [
                "type": "response.function_call_arguments.done",
                "call_id": "missing-arguments",
                "name": "get_member_weekly_summary",
            ],
            [
                "type": "response.function_call_arguments.done",
                "call_id": "non-string-arguments",
                "name": "get_member_weekly_summary",
                "arguments": 42,
            ],
            [
                "type": "response.function_call_arguments.done",
                "call_id": "malformed-arguments",
                "name": "get_member_weekly_summary",
                "arguments": "{bad",
            ],
            [
                "type": "response.function_call_arguments.done",
                "call_id": "non-object-arguments",
                "name": "get_member_weekly_summary",
                "arguments": "[]",
            ],
            [
                "type": "response.function_call_arguments.done",
                "call_id": "nonempty-object-arguments",
                "name": "get_member_weekly_summary",
                "arguments": #"{"member_id":"M-001"}"#,
            ],
        ]

        for fixture in invalidArguments {
            let callID = fixture["call_id"] as? String ?? ""
            #expect(
                OpenAIRealtimeWireDecoder.decode(try jsonData(fixture))
                    == .toolCall(
                        VoiceToolCall(callID: callID, kind: .invalidArguments)
                    )
            )
        }
    }

    @Test("visitor enrollment function calls decode only exact arguments")
    func visitorEnrollmentFunctionCallsDecode() throws {
        let begin = OpenAIRealtimeWireDecoder.decode(
            try jsonData([
                "type": "response.function_call_arguments.done",
                "call_id": "begin-call",
                "name": "begin_visitor_enrollment",
                "arguments": "{}",
            ])
        )
        #expect(
            begin == .toolCall(
                VoiceToolCall(callID: "begin-call", kind: .beginVisitorEnrollment)
            )
        )

        let complete = OpenAIRealtimeWireDecoder.decode(
            try jsonData([
                "type": "response.function_call_arguments.done",
                "call_id": "complete-call",
                "name": "complete_visitor_enrollment",
                "arguments": #"{"spoken_label":"Tony"}"#,
            ])
        )
        #expect(
            complete == .toolCall(
                VoiceToolCall(
                    callID: "complete-call",
                    kind: .completeVisitorEnrollment(
                        try VoiceMemberAddress(spokenLabel: "Tony")
                    )
                )
            )
        )

        let invalidCalls: [[String: Any]] = [
            [
                "type": "response.function_call_arguments.done",
                "call_id": "begin-extra",
                "name": "begin_visitor_enrollment",
                "arguments": #"{"consent":true}"#,
            ],
            [
                "type": "response.function_call_arguments.done",
                "call_id": "complete-missing",
                "name": "complete_visitor_enrollment",
                "arguments": "{}",
            ],
            [
                "type": "response.function_call_arguments.done",
                "call_id": "complete-extra",
                "name": "complete_visitor_enrollment",
                "arguments": #"{"spoken_label":"Tony","member_id":"must-not-cross"}"#,
            ],
            [
                "type": "response.function_call_arguments.done",
                "call_id": "complete-empty",
                "name": "complete_visitor_enrollment",
                "arguments": #"{"spoken_label":"  "}"#,
            ],
        ]

        for fixture in invalidCalls {
            let callID = try #require(fixture["call_id"] as? String)
            #expect(
                OpenAIRealtimeWireDecoder.decode(try jsonData(fixture))
                    == .toolCall(
                        VoiceToolCall(callID: callID, kind: .invalidArguments)
                    )
            )
        }
    }

    @Test("invalid names and call IDs fail closed without becoming voice failures")
    func invalidFunctionCallIdentityDecodeMatrix() throws {
        let invalidNames: [[String: Any]] = [
            [
                "type": "response.function_call_arguments.done",
                "call_id": "missing-name",
                "arguments": "{}",
            ],
            [
                "type": "response.function_call_arguments.done",
                "call_id": "non-string-name",
                "name": 42,
                "arguments": "{}",
            ],
            [
                "type": "response.function_call_arguments.done",
                "call_id": "empty-name",
                "name": "",
                "arguments": "{}",
            ],
            [
                "type": "response.function_call_arguments.done",
                "call_id": "whitespace-name",
                "name": " \n",
                "arguments": "{}",
            ],
        ]

        for fixture in invalidNames {
            let callID = fixture["call_id"] as? String ?? ""
            #expect(
                OpenAIRealtimeWireDecoder.decode(try jsonData(fixture))
                    == .toolCall(
                        VoiceToolCall(callID: callID, kind: .invalidArguments)
                    )
            )
        }

        let invalidCallIDs: [[String: Any]] = [
            [
                "type": "response.function_call_arguments.done",
                "name": "get_member_weekly_summary",
                "arguments": "{}",
            ],
            [
                "type": "response.function_call_arguments.done",
                "call_id": 42,
                "name": "get_member_weekly_summary",
                "arguments": "{}",
            ],
            [
                "type": "response.function_call_arguments.done",
                "call_id": "",
                "name": "get_member_weekly_summary",
                "arguments": "{}",
            ],
            [
                "type": "response.function_call_arguments.done",
                "call_id": " \n",
                "name": "get_member_weekly_summary",
                "arguments": "{}",
            ],
        ]

        for fixture in invalidCallIDs {
            #expect(
                OpenAIRealtimeWireDecoder.decode(try jsonData(fixture)) == nil
            )
        }
    }

    @Test("argument deltas and other provider events never produce tool calls")
    func partialFunctionCallEventsRemainIgnored() throws {
        let delta = OpenAIRealtimeWireDecoder.decode(
            try jsonData([
                "type": "response.function_call_arguments.delta",
                "call_id": "partial-call",
                "name": "get_member_weekly_summary",
                "delta": #"{"member_id":"M-001"}"#,
            ])
        )
        let other = OpenAIRealtimeWireDecoder.decode(
            try jsonData([
                "type": "response.output_text.done",
                "call_id": "other-call",
                "name": "get_member_weekly_summary",
                "arguments": "{}",
            ])
        )

        #expect(delta == .unknown("response.function_call_arguments.delta"))
        #expect(other == .unknown("response.output_text.done"))
        #expect(String(describing: delta).contains("M-001") == false)
        #expect(String(describing: other).contains("M-001") == false)
    }

    @Test("well-formed future events preserve only their type")
    func futureEventsAreUnknownWithoutPayloadRetention() throws {
        let sensitive = "secret-token-sdp-authorization"
        let decoded = OpenAIRealtimeWireDecoder.decode(
            try jsonData([
                "type": "future.event",
                "payload": sensitive,
            ])
        )

        #expect(decoded == .unknown("future.event"))
        #expect(String(describing: decoded).contains(sensitive) == false)
    }

    @Test("malformed and missing-type payloads become redacted errors")
    func malformedEventsDoNotExposeRawPayload() throws {
        let sensitive = "secret-token-sdp-authorization-provider-details"
        let malformed = OpenAIRealtimeWireDecoder.decode(
            Data("{\"type\":\"error\",\"details\":\"\(sensitive)".utf8)
        )
        let missingType = OpenAIRealtimeWireDecoder.decode(
            try jsonData(["details": sensitive])
        )

        #expect(malformed == .error)
        #expect(missingType == .error)
        #expect(String(describing: malformed).contains(sensitive) == false)
        #expect(String(describing: missingType).contains(sensitive) == false)
    }
}

private enum WireEventTestError: Error {
    case notObject(String)
    case missingObject(String)
}

private func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw WireEventTestError.notObject("root")
    }
    return object
}

private func object(
    _ parent: [String: Any],
    at key: String
) throws -> [String: Any] {
    guard let value = parent[key] as? [String: Any] else {
        throw WireEventTestError.missingObject(key)
    }
    return value
}
