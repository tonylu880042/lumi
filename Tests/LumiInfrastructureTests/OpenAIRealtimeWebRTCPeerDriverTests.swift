import Foundation
@testable import LumiInfrastructure
@preconcurrency import WebRTC
import Testing

@Suite("OpenAI Realtime WebRTC peer driver")
struct OpenAIRealtimeWebRTCPeerDriverTests {
    @Test("legacy remote audio tracks use the approved 2x gain")
    @MainActor
    func legacyRemoteAudioUsesApprovedGain() async throws {
        let factory = RTCPeerConnectionFactory()
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        let source = factory.audioSource(with: constraints)
        let track = factory.audioTrack(
            with: source,
            trackId: "legacy-remote"
        )
        let stream = factory.mediaStream(withStreamId: "legacy")
        stream.addAudioTrack(track)
        let driver = OpenAIRealtimeWebRTCPeerDriver(factory: factory)

        driver.configureRemoteAudio(in: stream)

        #expect(track.isEnabled)
        #expect(track.source.volume == 2.0)
        await driver.close()
    }

    @Test("Unified Plan receiver audio tracks use the approved 2x gain")
    @MainActor
    func unifiedPlanRemoteAudioUsesApprovedGain() async throws {
        let factory = RTCPeerConnectionFactory()
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        let source = factory.audioSource(with: constraints)
        let track = factory.audioTrack(
            with: source,
            trackId: "unified-plan-remote"
        )
        let receiverTrack: RTCMediaStreamTrack = track
        let driver = OpenAIRealtimeWebRTCPeerDriver(factory: factory)

        driver.configureRemoteAudioTrack(receiverTrack)

        #expect(track.isEnabled)
        #expect(track.source.volume == 2.0)
        await driver.close()
    }

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
