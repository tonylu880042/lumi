import LumiApplication
import Testing

@Suite("Voice session port contract")
struct VoiceSessionPortContractTests {
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
