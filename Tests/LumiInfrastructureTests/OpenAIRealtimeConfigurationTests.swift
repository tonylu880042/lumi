import LumiApplication
@testable import LumiInfrastructure
import Testing

@Suite("OpenAI Realtime configuration")
struct OpenAIRealtimeConfigurationTests {
    @Test("conversation prompt catalog centralizes editable response wording")
    func conversationPromptCatalogIsCanonical() throws {
        let address = try VoiceMemberAddress(spokenLabel: "tony")

        #expect(OpenAIConversationPrompts.basePersona ==
            OpenAIRealtimeConfiguration().instructions)
        #expect(OpenAIConversationPrompts.returningMember(address: address)
            .contains("很開心再見到你tony漂亮姊姊"))
        #expect(OpenAIConversationPrompts.returningMember(address: address)
            .contains("嚴禁呼叫任何工具"))
        #expect(OpenAIConversationPrompts.returningMember(address: address)
            .contains("只有在會員主動開口詢問"))
        #expect(OpenAIConversationPrompts.anonymousReturningMember
            .contains("不要說出姓名"))
        #expect(OpenAIConversationPrompts.enrollmentCapableVisitor
            .contains("我可以跟你認識嗎？"))
        #expect(OpenAIConversationPrompts.anonymousVisitor
            .contains("一般問候"))
        #expect(OpenAIConversationPrompts.preWorkoutReminder
            .contains("運動前提醒"))
        #expect(OpenAIConversationPrompts.preWorkoutReminder
            .contains("俐落收尾"))
        #expect(OpenAIConversationPrompts.postWorkoutReview
            .contains("運動後 review"))
        #expect(OpenAIConversationPrompts.postWorkoutReview
            .contains("收尾"))
        #expect(OpenAIConversationPrompts.debugFixtureDisclosure
            .contains("以下是開發測試資料"))
        #expect(OpenAIConversationPrompts.basePersona
            .contains("35字"))
        #expect(OpenAIConversationPrompts.basePersona
            .contains("極短句"))
        #expect(OpenAIConversationPrompts.enrollmentCapableVisitor
            .contains("35字"))
    }

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
