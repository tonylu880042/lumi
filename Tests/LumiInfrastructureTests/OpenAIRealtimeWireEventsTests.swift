import Foundation
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
        #expect(turnDetection["create_response"] as? Bool == true)
        #expect(turnDetection["interrupt_response"] as? Bool == true)

        let output = try object(audio, at: "output")
        #expect(output["voice"] as? String == configuration.voice)
        #expect(session["voice"] == nil)

        // Provider defaults remain in effect until product-approved tuning is
        // available from physical-device evidence.
        #expect(turnDetection["threshold"] == nil)
        #expect(turnDetection["prefix_padding_ms"] == nil)
        #expect(turnDetection["silence_duration_ms"] == nil)
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

    @Test("response.done only reports failed and incomplete responses")
    func responseDoneStatusesDecode() throws {
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

        #expect(failed == .responseFailed)
        #expect(incomplete == .responseFailed)
        #expect(cancelled == nil)
        #expect(completed == nil)
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
