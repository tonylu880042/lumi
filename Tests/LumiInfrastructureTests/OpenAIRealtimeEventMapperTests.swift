import LumiApplication
@testable import LumiInfrastructure
import Testing

@Suite("OpenAI Realtime event mapper")
struct OpenAIRealtimeEventMapperTests {
    @Test("provider and mapped events are equatable Sendable values")
    func eventsAreStableValues() async {
        let providerEvent = OpenAIRealtimeProviderEvent.unknown("future.event")
        let mappedEvent = OpenAIRealtimeMappedEvent.voice(.failure)

        #expect(providerEvent == .unknown("future.event"))
        #expect(mappedEvent == .voice(.failure))
        acceptsSendable(providerEvent)
        acceptsSendable(mappedEvent)
    }

    @Test("tool calls are provider-neutral values without raw provider metadata")
    func toolCallProviderEventIsStableAndRedacted() async {
        let toolCall = VoiceToolCall(
            callID: "opaque-call-id",
            kind: .getMemberWeeklySummary
        )
        let providerEvent = OpenAIRealtimeProviderEvent.toolCall(toolCall)

        #expect(providerEvent == .toolCall(toolCall))
        #expect(String(describing: providerEvent).contains("raw-provider-name") == false)
        #expect(String(describing: providerEvent).contains("raw-provider-arguments") == false)
        acceptsSendable(providerEvent)
    }

    @Test("session readiness is exposed separately from voice events")
    func sessionCreatedMapsToReadinessMarker() async {
        let mapper = OpenAIRealtimeEventMapper()

        #expect(await mapper.map(.sessionCreated) == [.ready])
        #expect(await mapper.map(.unknown("future.event")).isEmpty)
    }

    @Test("speech starts as user speech when assistant output is inactive")
    func speechStartedMapsToUserSpeechStartedWhenIdle() async {
        let mapper = OpenAIRealtimeEventMapper()

        #expect(await mapper.map(.inputAudioSpeechStarted) == [.voice(.userSpeechStarted)])
    }

    @Test("speech during assistant output emits interruption only")
    func speechStartedInterruptsActiveAssistantOutput() async {
        let mapper = OpenAIRealtimeEventMapper()

        #expect(await mapper.map(.outputAudioStarted) == [.voice(.assistantOutputStarted)])
        #expect(await mapper.map(.inputAudioSpeechStarted) == [.voice(.assistantInterrupted)])
        #expect(await mapper.map(.outputAudioStopped) == [.voice(.assistantOutputEnded)])
        #expect(await mapper.map(.inputAudioSpeechStarted) == [.voice(.userSpeechStarted)])
    }

    @Test("first output after user speech ends announces response readiness once")
    func responseReadinessIsArmedBySpeechEnded() async {
        let mapper = OpenAIRealtimeEventMapper()

        #expect(await mapper.map(.inputAudioSpeechStopped) == [.voice(.userSpeechEnded)])
        #expect(await mapper.map(.outputAudioStarted) == [
            .voice(.responseReady),
            .voice(.assistantOutputStarted),
        ])
        #expect(await mapper.map(.outputAudioStarted).isEmpty)
    }

    @Test("initial greeting output becomes active without response readiness")
    func initialGreetingOutputDoesNotAnnounceResponseReadiness() async {
        let mapper = OpenAIRealtimeEventMapper()

        #expect(await mapper.map(.outputAudioStarted) == [.voice(.assistantOutputStarted)])
        #expect(await mapper.map(.inputAudioSpeechStarted) == [.voice(.assistantInterrupted)])
        #expect(await mapper.map(.outputAudioCleared) == [.voice(.assistantOutputEnded)])
        #expect(await mapper.map(.inputAudioSpeechStarted) == [.voice(.userSpeechStarted)])
    }

    @Test("stopped and cleared output both clear assistant activity")
    func outputEndEventsClearActiveState() async {
        let mapper = OpenAIRealtimeEventMapper()

        #expect(await mapper.map(.outputAudioStarted) == [.voice(.assistantOutputStarted)])
        #expect(await mapper.map(.outputAudioStopped) == [.voice(.assistantOutputEnded)])
        #expect(await mapper.map(.inputAudioSpeechStarted) == [.voice(.userSpeechStarted)])

        #expect(await mapper.map(.outputAudioStarted) == [.voice(.assistantOutputStarted)])
        #expect(await mapper.map(.outputAudioCleared) == [.voice(.assistantOutputEnded)])
        #expect(await mapper.map(.inputAudioSpeechStarted) == [.voice(.userSpeechStarted)])
    }

    @Test("provider failures map to one semantic failure event")
    func failuresMapToVoiceFailure() async {
        let mapper = OpenAIRealtimeEventMapper()

        #expect(await mapper.map(.error) == [.voice(.failure)])
        #expect(await mapper.map(.responseFailed) == [.voice(.failure)])
    }

    @Test("tool calls stay on the tool boundary and do not become voice lifecycle events")
    func toolCallsAreNotVoiceEvents() async {
        let mapper = OpenAIRealtimeEventMapper()
        let toolCall = VoiceToolCall(
            callID: "opaque-call-id",
            kind: .getMemberWeeklySummary
        )

        #expect(await mapper.map(.toolCall(toolCall)).isEmpty)
    }
}

private func acceptsSendable(_ value: any Sendable) {
    _ = value
}
