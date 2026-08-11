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
}

private func acceptsSendable(_ event: any Sendable) {
    _ = event
}
