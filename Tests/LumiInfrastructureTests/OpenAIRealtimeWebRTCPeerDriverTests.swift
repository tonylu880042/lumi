import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("OpenAI Realtime WebRTC peer driver")
struct OpenAIRealtimeWebRTCPeerDriverTests {
    @Test("real WebRTC 151.0.0 creates an audio and data-channel offer")
    @MainActor
    func createsAudioAndDataOfferWithoutMicrophonePermission() async throws {
        let driver = OpenAIRealtimeWebRTCPeerDriver()

        try await driver.prepare()
        let offer = try await driver.createLocalOffer()

        #expect(offer.hasPrefix("v=0"))
        #expect(offer.contains("m=audio"))
        #expect(offer.contains("m=application"))
        #expect(driver.dataChannelLabel == "oai-events")
        #expect(driver.dataChannelIsOrdered)
        #expect(driver.localMicrophoneTrackEnabled)

        await driver.close()
    }

    @Test("remote SDP framework rejection maps to invalidRemoteDescription")
    @MainActor
    func mapsInvalidRemoteDescription() async throws {
        let driver = OpenAIRealtimeWebRTCPeerDriver()
        try await driver.prepare()

        await #expect(throws: OpenAIRealtimePeerDriverError.invalidRemoteDescription) {
            try await driver.setRemoteAnswer("not an SDP answer")
        }

        await driver.close()
    }

    @Test("data callbacks forward exact bytes and stop after close")
    @MainActor
    func forwardsDataAndSuppressesPostCloseEvents() async throws {
        let driver = OpenAIRealtimeWebRTCPeerDriver()
        let updates = await driver.eventUpdates()
        let expected = Data([0x00, 0x7F, 0xFF, 0x01])

        driver.receiveData(expected)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == expected)

        await driver.close()
        driver.receiveData(Data([0x02]))
        #expect(await iterator.next() == nil)
        await driver.close()
    }

    @Test("close is idempotent and finishes event stream")
    @MainActor
    func closeFinishesStream() async throws {
        let driver = OpenAIRealtimeWebRTCPeerDriver()
        let updates = await driver.eventUpdates()

        await driver.close()
        await driver.close()

        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test("terminal callback seam finishes once and suppresses later data")
    @MainActor
    func terminalHandlerIsIdempotent() async throws {
        let driver = OpenAIRealtimeWebRTCPeerDriver()
        let updates = await driver.eventUpdates()

        driver.handleTerminalEvent()
        driver.handleTerminalEvent()
        driver.receiveData(Data([0x03]))

        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == nil)

        await driver.close()
    }

    @Test("sending before preparation reports unavailable data channel")
    @MainActor
    func sendingWithoutPreparationIsTyped() async throws {
        let driver = OpenAIRealtimeWebRTCPeerDriver()

        await #expect(throws: OpenAIRealtimePeerDriverError.dataChannelUnavailable) {
            try await driver.send(Data([0x01]))
        }

        await driver.close()
    }
}
