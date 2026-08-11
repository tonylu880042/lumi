import LumiInfrastructure
import Testing

@Suite("OpenAI Realtime configuration")
struct OpenAIRealtimeConfigurationTests {
    @Test("default configuration uses the Phase 2.1 model, voice, and persona instructions")
    func defaultConfigurationIsCanonical() {
        let configuration = OpenAIRealtimeConfiguration()

        #expect(configuration.model == "gpt-realtime-2.1-mini")
        #expect(configuration.voice == "marin")
        #expect(configuration.instructions.contains("台灣繁體中文"))
        #expect(configuration.instructions.contains("自然台灣華語"))
        #expect(configuration.instructions.contains("1–2句"))
        #expect(configuration.instructions.contains("親切"))
        #expect(configuration.instructions.contains("女性角色"))
        #expect(configuration.instructions.contains("醫療診斷"))
    }

    @Test("explicit overrides preserve the exact supplied values")
    func explicitOverridesAreExact() {
        let configuration = OpenAIRealtimeConfiguration(
            model: "custom-model",
            voice: "custom-voice",
            instructions: "custom instructions"
        )

        #expect(configuration == OpenAIRealtimeConfiguration(
            model: "custom-model",
            voice: "custom-voice",
            instructions: "custom instructions"
        ))
        #expect(configuration.model == "custom-model")
        #expect(configuration.voice == "custom-voice")
        #expect(configuration.instructions == "custom instructions")
    }

    @Test("explicit configuration does not add empty-value validation")
    func explicitEmptyValuesRemainAllowed() {
        let configuration = OpenAIRealtimeConfiguration(
            model: "",
            voice: "",
            instructions: ""
        )

        #expect(configuration.model.isEmpty)
        #expect(configuration.voice.isEmpty)
        #expect(configuration.instructions.isEmpty)
    }

    @Test("configuration is Equatable and Sendable")
    func configurationConformsToValueContracts() {
        let configuration = OpenAIRealtimeConfiguration()
        #expect(configuration == OpenAIRealtimeConfiguration())
        acceptsSendable(configuration)
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
