import LumiApplication
import Testing

@Suite("Voice session port contract")
struct VoiceSessionPortContractTests {
    @Test("conversation directions are payload-free and Sendable")
    func conversationDirectionsArePayloadFree() {
        let directions: [VoiceConversationDirection] = [
            .general,
            .preWorkoutReminder,
            .postWorkoutReview,
        ]

        #expect(directions == [
            .general,
            .preWorkoutReminder,
            .postWorkoutReview,
        ])
        #expect(Mirror(reflecting: VoiceConversationDirection.general).children.isEmpty)
        #expect(Mirror(reflecting: VoiceConversationDirection.preWorkoutReminder).children.isEmpty)
        #expect(Mirror(reflecting: VoiceConversationDirection.postWorkoutReview).children.isEmpty)
        acceptsSendable(directions)
    }

    @Test("legacy voice ports keep the start contract through the direction default")
    func legacyVoicePortsKeepStartContract() async throws {
        let voice = LegacyVoiceSessionPort()

        try await voice.start(
            context: .visitor,
            direction: .postWorkoutReview
        )

        #expect(await voice.startContexts == [.visitor])
    }

    @Test("assistant interruption is payload-free and equatable")
    func assistantInterruptionIsPayloadFreeAndEquatable() {
        let event = VoiceSessionEvent.assistantInterrupted

        #expect(event == .assistantInterrupted)
        #expect(Mirror(reflecting: event).children.isEmpty)
        acceptsSendable(event)
    }

    @Test("authorization-required error is payload-free and equatable")
    func authorizationRequiredIsPayloadFreeAndEquatable() {
        let error = VoiceSessionAuthorizationError.authorizationRequired

        #expect(error == .authorizationRequired)
        #expect(Mirror(reflecting: error).children.isEmpty)
        #expect(!String(describing: error).contains("authorization-marker"))
        #expect(!String(reflecting: error).contains("authorization-marker"))
        acceptsSendable(error)
    }
}

private func acceptsSendable(_ event: any Sendable) {
    _ = event
}

private actor LegacyVoiceSessionPort: VoiceSessionPort {
    private(set) var startContexts: [VoiceContext] = []

    func start(context: VoiceContext) async throws {
        startContexts.append(context)
    }

    func eventUpdates() async -> AsyncStream<VoiceSessionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func stop() async {}
}
