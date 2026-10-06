import Foundation
import LumiApplication
@testable import LumiInfrastructure
import Testing

@Suite("Member exercise disclosure wire contract")
struct MemberExerciseDisclosureWireTests {
    @Test("advertises only bounded disclosure values for a known member")
    func advertisesBoundedDisclosureTool() throws {
        let configuration = OpenAIRealtimeConfiguration(
            model: "gpt-test",
            voice: "cedar",
            instructions: "test",
            maxResponseOutputTokens: 128,
            usesExternalGreeting: false,
            allowsConversationClosing: false
        )

        let data = try OpenAIRealtimeWireEncoder.sessionUpdate(
            for: configuration,
            enablesMemberMemoryTool: true
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let session = try #require(object["session"] as? [String: Any])
        let tools = try #require(session["tools"] as? [[String: Any]])
        let tool = try #require(
            tools.first(where: { $0["name"] as? String == "record_member_exercise_disclosure" })
        )
        let parameters = try #require(tool["parameters"] as? [String: Any])
        let properties = try #require(parameters["properties"] as? [String: Any])
        let disclosure = try #require(properties["disclosure"] as? [String: Any])
        #expect(disclosure["enum"] as? [String] == ["preparing", "just_completed", "completed_today"])
        #expect(parameters["additionalProperties"] as? Bool == false)
    }

    @Test("decodes only valid disclosure arguments")
    func decodesBoundedArguments() throws {
        let valid = OpenAIRealtimeWireDecoder.decode(
            Data(
                #"{"type":"response.function_call_arguments.done","call_id":"exercise-1","name":"record_member_exercise_disclosure","arguments":"{\"disclosure\":\"completed_today\"}"}"#.utf8
            )
        )
        #expect(
            valid == .toolCall(
                VoiceToolCall(
                    callID: "exercise-1",
                    kind: .recordExerciseDisclosure(.completedToday)
                )
            )
        )

        let invalid = OpenAIRealtimeWireDecoder.decode(
            Data(
                #"{"type":"response.function_call_arguments.done","call_id":"exercise-2","name":"record_member_exercise_disclosure","arguments":"{\"disclosure\":\"yesterday\"}"}"#.utf8
            )
        )
        #expect(
            invalid == .toolCall(
                VoiceToolCall(callID: "exercise-2", kind: .invalidArguments)
            )
        )
    }
}
