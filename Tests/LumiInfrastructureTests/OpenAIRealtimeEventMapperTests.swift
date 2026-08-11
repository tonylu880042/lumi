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

        #expect(await mapper.map(.outputAudioStarted).isEmpty)
        #expect(await mapper.map(.inputAudioSpeechStarted) == [.voice(.assistantInterrupted)])
        #expect(await mapper.map(.outputAudioStopped).isEmpty)
        #expect(await mapper.map(.inputAudioSpeechStarted) == [.voice(.userSpeechStarted)])
    }

    @Test("first output after user speech ends announces response readiness once")
    func responseReadinessIsArmedBySpeechEnded() async {
        let mapper = OpenAIRealtimeEventMapper()

        #expect(await mapper.map(.inputAudioSpeechStopped) == [.voice(.userSpeechEnded)])
        #expect(await mapper.map(.outputAudioStarted) == [.voice(.responseReady)])
        #expect(await mapper.map(.outputAudioStarted).isEmpty)
    }

    @Test("initial greeting output becomes active without response readiness")
    func initialGreetingOutputDoesNotAnnounceResponseReadiness() async {
        let mapper = OpenAIRealtimeEventMapper()

        #expect(await mapper.map(.outputAudioStarted).isEmpty)
        #expect(await mapper.map(.inputAudioSpeechStarted) == [.voice(.assistantInterrupted)])
        #expect(await mapper.map(.outputAudioCleared).isEmpty)
        #expect(await mapper.map(.inputAudioSpeechStarted) == [.voice(.userSpeechStarted)])
    }

    @Test("stopped and cleared output both clear assistant activity")
    func outputEndEventsClearActiveState() async {
        let mapper = OpenAIRealtimeEventMapper()

        #expect(await mapper.map(.outputAudioStarted).isEmpty)
        #expect(await mapper.map(.outputAudioStopped).isEmpty)
        #expect(await mapper.map(.inputAudioSpeechStarted) == [.voice(.userSpeechStarted)])

        #expect(await mapper.map(.outputAudioStarted).isEmpty)
        #expect(await mapper.map(.outputAudioCleared).isEmpty)
        #expect(await mapper.map(.inputAudioSpeechStarted) == [.voice(.userSpeechStarted)])
    }

    @Test("provider failures map to one semantic failure event")
    func failuresMapToVoiceFailure() async {
        let mapper = OpenAIRealtimeEventMapper()

        #expect(await mapper.map(.error) == [.voice(.failure)])
        #expect(await mapper.map(.responseFailed) == [.voice(.failure)])
    }
}

private func acceptsSendable(_ value: any Sendable) {
    _ = value
}
