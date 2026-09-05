import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("OpenAI WebRTC transport startup")
struct OpenAIWebRTCTransportTests {
    @Test("connects in the approved order and routes exact offer, token, and answer")
    func connectsInOrderAndRoutesSDP() async throws {
        let trace = Trace()
        let clock = TestClock(
            now: Date(timeIntervalSince1970: 100),
            trace: trace
        )
        let permission = RecordingPermission(trace: trace)
        let audio = RecordingAudioController(trace: trace)
        let peer = RecordingPeerDriver(trace: trace, offer: "offer-marker")
        let signaling = RecordingSignaling(trace: trace, answer: "answer-marker")
        let transport = makeTransport(
            clock: clock,
            permission: permission,
            audio: audio,
            peer: peer,
            signaling: signaling
        )
        let secret = try makeSecret(value: "token-marker", expiresAt: 200)

        try await transport.connect(
            clientSecret: secret,
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )

        #expect(await trace.values == [
            "clock",
            "permission",
            "audio.activate",
            "peer.prepare",
            "peer.offer",
            "clock",
            "signaling.offer-marker.token-marker",
            "peer.answer-marker",
        ])
        #expect(await signaling.receivedOffer == "offer-marker")
        #expect(await signaling.receivedToken == "token-marker")
        #expect(await peer.receivedAnswer == "answer-marker")

        await transport.close()
    }

    @Test("rejects a credential expiring exactly now before permission")
    func rejectsCredentialExpiringExactlyNowBeforePermission() async throws {
        let trace = Trace()
        let clock = TestClock(
            now: Date(timeIntervalSince1970: 100),
            trace: trace
        )
        let permission = RecordingPermission(trace: trace)
        let audio = RecordingAudioController(trace: trace)
        let peer = RecordingPeerDriver(trace: trace)
        let signaling = RecordingSignaling(trace: trace)
        let transport = makeTransport(
            clock: clock,
            permission: permission,
            audio: audio,
            peer: peer,
            signaling: signaling
        )

        await #expect(throws: OpenAIWebRTCTransportError.expiredClientSecret) {
            try await transport.connect(
                clientSecret: try makeSecret(value: "token-marker", expiresAt: 100),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .initial
            )
        }

        #expect(await trace.values == ["clock"])
        #expect(await permission.callCount == 0)
        #expect(await audio.activateCallCount == 0)
        #expect(await peer.prepareCallCount == 0)
        #expect(await signaling.callCount == 0)
    }

    @Test("rejects a credential that expired before connect without side effects")
    func rejectsCredentialExpiredBeforeConnect() async throws {
        let trace = Trace()
        let clock = TestClock(now: Date(timeIntervalSince1970: 101))
        let permission = RecordingPermission(trace: trace)
        let audio = RecordingAudioController(trace: trace)
        let peer = RecordingPeerDriver(trace: trace)
        let signaling = RecordingSignaling(trace: trace)
        let transport = makeTransport(
            clock: clock,
            permission: permission,
            audio: audio,
            peer: peer,
            signaling: signaling
        )

        await #expect(throws: OpenAIWebRTCTransportError.expiredClientSecret) {
            try await transport.connect(
                clientSecret: try makeSecret(value: "token-marker", expiresAt: 100),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .reconnect
            )
        }

        #expect(await permission.callCount == 0)
        #expect(await audio.activateCallCount == 0)
        #expect(await peer.prepareCallCount == 0)
        #expect(await signaling.callCount == 0)
    }

    @Test("expiry during permission prepares local media but blocks signaling and cleans up")
    func rejectsCredentialExpiredDuringPermission() async throws {
        let trace = Trace()
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let permission = RecordingPermission(trace: trace) {
            await clock.setNow(Date(timeIntervalSince1970: 100))
            await clock.setNow(Date(timeIntervalSince1970: 200))
        }
        let audio = RecordingAudioController(trace: trace)
        let peer = RecordingPeerDriver(trace: trace)
        let signaling = RecordingSignaling(trace: trace)
        let transport = makeTransport(
            clock: clock,
            permission: permission,
            audio: audio,
            peer: peer,
            signaling: signaling
        )

        await #expect(throws: OpenAIWebRTCTransportError.expiredClientSecret) {
            try await transport.connect(
                clientSecret: try makeSecret(value: "token-marker", expiresAt: 150),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .initial
            )
        }

        #expect(await permission.callCount == 1)
        #expect(await audio.activateCallCount == 1)
        #expect(await audio.deactivateCallCount == 1)
        #expect(await peer.prepareCallCount == 1)
        #expect(await peer.createLocalOfferCallCount == 1)
        #expect(await peer.closeCallCount == 1)
        #expect(await signaling.callCount == 0)
    }

    @Test("permission denial maps to a typed error without downstream effects")
    func permissionDeniedHasNoDownstreamEffects() async throws {
        let trace = Trace()
        let permission = RecordingPermission(
            trace: trace,
            error: OpenAIRealtimeMicrophonePermissionError.denied
        )
        let audio = RecordingAudioController(trace: trace)
        let peer = RecordingPeerDriver(trace: trace)
        let signaling = RecordingSignaling(trace: trace)
        let transport = makeTransport(
            clock: TestClock(now: Date(timeIntervalSince1970: 100)),
            permission: permission,
            audio: audio,
            peer: peer,
            signaling: signaling
        )

        await #expect(throws: OpenAIWebRTCTransportError.microphonePermissionDenied) {
            try await transport.connect(
                clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .initial
            )
        }

        #expect(await permission.callCount == 1)
        #expect(await audio.activateCallCount == 0)
        #expect(await peer.prepareCallCount == 0)
        #expect(await signaling.callCount == 0)
    }

    @Test("cancellation while signaling cleans up peer and audio and preserves CancellationError")
    func cancellationDuringSignalingCleansUp() async throws {
        let permission = RecordingPermission()
        let audio = RecordingAudioController()
        let peer = RecordingPeerDriver(offer: "offer-marker")
        let signaling = BlockingSignaling()
        let transport = makeTransport(
            clock: TestClock(now: Date(timeIntervalSince1970: 100)),
            permission: permission,
            audio: audio,
            peer: peer,
            signaling: signaling
        )

        let connection = Task {
            try await transport.connect(
                clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .initial
            )
        }
        #expect(await waitUntil { await signaling.started })

        connection.cancel()
        await #expect(throws: CancellationError.self) {
            try await connection.value
        }
        #expect(await waitUntil {
            let peerClosed = await peer.closeCallCount == 1
            let audioDeactivated = await audio.deactivateCallCount == 1
            return peerClosed && audioDeactivated
        })
        #expect(await signaling.cancellationCount > 0)
    }

    @Test("maps audio, peer, signaling, and remote-description failures without details")
    func mapsRepresentativeFailuresWithoutDetails() async throws {
        let audioMarker = "audio-sensitive-marker"
        let audio = RecordingAudioController(
            error: OpenAIRealtimeAudioSessionError.activationFailed
        )
        let audioTransport = makeTransport(
            clock: TestClock(now: Date(timeIntervalSince1970: 100)),
            permission: RecordingPermission(),
            audio: audio,
            peer: RecordingPeerDriver(),
            signaling: RecordingSignaling()
        )
        let audioError = await thrownTransportError {
            try await audioTransport.connect(
                clientSecret: try makeSecret(value: audioMarker, expiresAt: 200),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .initial
            )
        }
        #expect(audioError == .audioSessionFailure)
        assertRedacted(audioError, markers: [audioMarker])
        #expect(await audio.deactivateCallCount == 1)

        let peerMarker = "peer-sensitive-marker"
        let peer = RecordingPeerDriver(
            error: OpenAIRealtimePeerDriverError.offerCreationFailed
        )
        let peerAudio = RecordingAudioController()
        let peerTransport = makeTransport(
            clock: TestClock(now: Date(timeIntervalSince1970: 100)),
            permission: RecordingPermission(),
            audio: peerAudio,
            peer: peer,
            signaling: RecordingSignaling()
        )
        let peerError = await thrownTransportError {
            try await peerTransport.connect(
                clientSecret: try makeSecret(value: peerMarker, expiresAt: 200),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .initial
            )
        }
        #expect(peerError == .peerFailure)
        assertRedacted(peerError, markers: [peerMarker])
        #expect(await peer.closeCallCount == 1)
        #expect(await peerAudio.deactivateCallCount == 1)

        let tokenMarker = "signaling-token-sensitive-marker"
        let offerMarker = "signaling-offer-sensitive-marker"
        let signalingPeer = RecordingPeerDriver(offer: offerMarker)
        let signalingAudio = RecordingAudioController()
        let signaling = RecordingSignaling(
            error: OpenAIRealtimeSDPSignalingError.httpStatus(statusCode: 401)
        )
        let signalingTransport = makeTransport(
            clock: TestClock(now: Date(timeIntervalSince1970: 100)),
            permission: RecordingPermission(),
            audio: signalingAudio,
            peer: signalingPeer,
            signaling: signaling
        )
        let signalingError = await thrownTransportError {
            try await signalingTransport.connect(
                clientSecret: try makeSecret(value: tokenMarker, expiresAt: 200),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .initial
            )
        }
        #expect(signalingError == .signalingRejected(statusCode: 401))
        assertRedacted(signalingError, markers: [tokenMarker, offerMarker])
        #expect(await signalingPeer.closeCallCount == 1)
        #expect(await signalingAudio.deactivateCallCount == 1)

        let remotePeer = RecordingPeerDriver(
            answerError: OpenAIRealtimePeerDriverError.invalidRemoteDescription
        )
        let remoteAudio = RecordingAudioController()
        let remoteTransport = makeTransport(
            clock: TestClock(now: Date(timeIntervalSince1970: 100)),
            permission: RecordingPermission(),
            audio: remoteAudio,
            peer: remotePeer,
            signaling: RecordingSignaling(answer: "remote-answer-sensitive-marker")
        )
        let remoteError = await thrownTransportError {
            try await remoteTransport.connect(
                clientSecret: try makeSecret(value: tokenMarker, expiresAt: 200),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .initial
            )
        }
        #expect(remoteError == .invalidRemoteDescription)
        assertRedacted(remoteError, markers: [tokenMarker, "remote-answer-sensitive-marker"])
        #expect(await remotePeer.closeCallCount == 1)
        #expect(await remoteAudio.deactivateCallCount == 1)
    }

    @Test("factory builder returns a fresh transport for every call")
    func factoryReturnsFreshTransportInstances() async throws {
        let factory = OpenAIWebRTCTransportFactory {
            makeTransport(
                clock: TestClock(now: Date(timeIntervalSince1970: 100)),
                permission: RecordingPermission(),
                audio: RecordingAudioController(),
                peer: RecordingPeerDriver(),
                signaling: RecordingSignaling()
            )
        }

        let first = await factory.makeTransport()
        let second = await factory.makeTransport()
        let firstID = ObjectIdentifier(first as AnyObject)
        let secondID = ObjectIdentifier(second as AnyObject)

        #expect(firstID != secondID)
    }

    @Test("event stream stays reserved and finishes cleanly on close")
    func eventStreamIsStableUntilClose() async throws {
        let peer = RecordingPeerDriver()
        let transport = makeTransport(
            clock: TestClock(now: Date(timeIntervalSince1970: 100)),
            permission: RecordingPermission(),
            audio: RecordingAudioController(),
            peer: peer,
            signaling: RecordingSignaling()
        )
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )
        #expect(await peer.eventUpdatesCallCount == 1)

        await transport.close()
        await peer.emit(rawEvent(type: "input_audio_buffer.speech_started"))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test("initial session handshake sends exact update then greeting before readiness")
    func initialHandshakeSendsOrderedClientEventsBeforeReadiness() async throws {
        let configuration = OpenAIRealtimeConfiguration(
            model: "model-marker",
            voice: "voice-marker",
            instructions: "instructions-marker"
        )
        let peer = RecordingPeerDriver()
        let transport = makeTransport(peer: peer)
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: configuration,
            purpose: .initial
        )

        await peer.emit(rawEvent(type: "session.created"))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .sessionCreated)
        #expect(await peer.sentData == [
            try OpenAIRealtimeWireEncoder.sessionUpdate(for: configuration),
            try OpenAIRealtimeWireEncoder.responseCreate(),
        ])
    }

    @Test("reconnect session handshake sends update but never replays greeting")
    func reconnectHandshakeOmitsGreeting() async throws {
        let configuration = OpenAIRealtimeConfiguration(
            model: "model-marker",
            voice: "voice-marker",
            instructions: "instructions-marker"
        )
        let peer = RecordingPeerDriver()
        let transport = makeTransport(peer: peer)
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: configuration,
            purpose: .reconnect
        )

        await peer.emit(rawEvent(type: "session.created"))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .sessionCreated)
        #expect(await peer.sentData == [
            try OpenAIRealtimeWireEncoder.sessionUpdate(for: configuration),
        ])
    }

    @Test("standby session handshake sends update without greeting and enables immediate send")
    func standbyHandshakeEnablesImmediateSend() async throws {
        let configuration = OpenAIRealtimeConfiguration(
            model: "model-marker",
            voice: "voice-marker",
            instructions: "instructions-marker"
        )
        let peer = RecordingPeerDriver()
        let transport = makeTransport(peer: peer)
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: configuration,
            purpose: .standby
        )

        await peer.emit(rawEvent(type: "session.created"))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .sessionCreated)
        #expect(await peer.sentData == [
            try OpenAIRealtimeWireEncoder.sessionUpdate(for: configuration),
        ])

        let greeting = try OpenAIRealtimeWireEncoder.responseCreate()
        try await transport.send(greeting)
        #expect(await peer.sentData == [
            try OpenAIRealtimeWireEncoder.sessionUpdate(for: configuration),
            greeting,
        ])
    }

    @Test("enabled initial handshake sends the tool schema then greeting")
    func enabledInitialHandshakeSendsToolSchemaAndGreeting() async throws {
        let configuration = OpenAIRealtimeConfiguration(
            model: "model-marker",
            voice: "voice-marker",
            instructions: "instructions-marker"
        )
        let peer = RecordingPeerDriver()
        let transport = makeTransport(peer: peer)
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: configuration,
            purpose: .initial,
            enablesWeeklySummaryTool: true
        )

        await peer.emit(rawEvent(type: "session.created"))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .sessionCreated)
        #expect(await peer.sentData == [
            try OpenAIRealtimeWireEncoder.sessionUpdate(
                for: configuration,
                enablesWeeklySummaryTool: true
            ),
            try OpenAIRealtimeWireEncoder.responseCreate(),
        ])
    }

    @Test("enabled reconnect handshake sends the tool schema without greeting")
    func enabledReconnectHandshakeSendsToolSchemaWithoutGreeting() async throws {
        let configuration = OpenAIRealtimeConfiguration(
            model: "model-marker",
            voice: "voice-marker",
            instructions: "instructions-marker"
        )
        let peer = RecordingPeerDriver()
        let transport = makeTransport(peer: peer)
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: configuration,
            purpose: .reconnect,
            enablesWeeklySummaryTool: true
        )

        await peer.emit(rawEvent(type: "session.created"))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .sessionCreated)
        #expect(await peer.sentData == [
            try OpenAIRealtimeWireEncoder.sessionUpdate(
                for: configuration,
                enablesWeeklySummaryTool: true
            ),
        ])
    }

    @Test("send forwards exact data only after the session handshake")
    func sendForwardsExactDataAfterHandshake() async throws {
        let peer = RecordingPeerDriver()
        let transport = makeTransport(peer: peer)
        let updates = await transport.eventUpdates()
        let payload = Data("exact-tool-result-payload".utf8)

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .reconnect
        )
        await peer.emit(rawEvent(type: "session.created"))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .sessionCreated)

        try await transport.send(payload)

        #expect(await peer.sentData.last == payload)
    }

    @Test("send before readiness and after close fail without ending the event stream")
    func sendLifecycleGuardsAreRedactedAndNonTerminal() async throws {
        let peer = RecordingPeerDriver()
        let transport = makeTransport(peer: peer)
        let updates = await transport.eventUpdates()
        let payload = Data("early-tool-result-payload".utf8)

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .reconnect
        )
        await #expect(throws: OpenAIWebRTCTransportError.dataChannelUnavailable) {
            try await transport.send(payload)
        }
        #expect(await peer.sentData.isEmpty)

        await transport.close()
        await #expect(throws: OpenAIWebRTCTransportError.closed) {
            try await transport.send(payload)
        }
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test("send failures map to redacted transport errors without closing")
    func sendFailureIsRedactedAndNonTerminal() async throws {
        let marker = "provider-sensitive-send-marker"
        let peer = RecordingPeerDriver(
            sendError: OpenAIRealtimePeerDriverError.dataSendFailed,
            failSendOn: 3
        )
        let transport = makeTransport(peer: peer)
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )
        await peer.emit(rawEvent(type: "session.created"))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .sessionCreated)

        let error = await thrownTransportError {
            try await transport.send(Data(marker.utf8))
        }
        #expect(error == .peerFailure)
        assertRedacted(error, markers: [marker])
        #expect(await peer.closeCallCount == 0)
    }

    @Test("send cancellation preserves CancellationError and does not close")
    func sendCancellationPreservesCancellation() async throws {
        let peer = RecordingPeerDriver(blockSend: true, blockSendOn: 3)
        let transport = makeTransport(peer: peer)
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )
        await peer.emit(rawEvent(type: "session.created"))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .sessionCreated)

        let sendTask = Task {
            try await transport.send(Data("cancel-me".utf8))
        }
        #expect(await waitUntil { await peer.sendStarted })
        sendTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await sendTask.value
        }
        #expect(await peer.sendCancellationCount == 1)
        #expect(await peer.closeCallCount == 0)
    }

    @Test("duplicate session.created does not resend client events or readiness")
    func duplicateSessionCreatedIsIgnored() async throws {
        let peer = RecordingPeerDriver()
        let transport = makeTransport(peer: peer)
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )

        await peer.emit(rawEvent(type: "session.created"))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .sessionCreated)
        await peer.emit(rawEvent(type: "session.created"))
        for _ in 0 ..< 8 { await Task.yield() }
        #expect(await peer.sentData.count == 2)
        await transport.close()
        #expect(await iterator.next() == nil)
    }

    @Test("forwards decoded provider events and ignores cancelled or completed responses")
    func forwardsDecodedProviderEvents() async throws {
        let peer = RecordingPeerDriver()
        let transport = makeTransport(peer: peer)
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )

        await peer.emit(rawEvent(type: "session.created"))
        await peer.emit(rawEvent(type: "input_audio_buffer.speech_started"))
        await peer.emit(rawEvent(type: "input_audio_buffer.speech_stopped"))
        await peer.emit(rawCommittedInput(itemID: "forwarded-turn"))
        await peer.emit(rawEvent(type: "output_audio_buffer.started"))
        await peer.emit(rawEvent(type: "output_audio_buffer.stopped"))
        await peer.emit(rawEvent(type: "output_audio_buffer.cleared"))
        await peer.emit(rawResponseDone(status: "failed"))
        await peer.emit(rawResponseDone(status: "incomplete"))
        await peer.emit(rawResponseDone(status: "cancelled"))
        await peer.emit(rawResponseDone(status: "completed"))
        await peer.emit(rawEvent(type: "error"))
        await peer.emit(rawEvent(type: "future.event"))
        await peer.emit(Data("{malformed".utf8))

        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .sessionCreated)
        let expected: [OpenAIRealtimeProviderEvent] = [
            .inputAudioSpeechStarted,
            .inputAudioSpeechStopped,
            .outputAudioStarted,
            .outputAudioStopped,
            .outputAudioCleared,
            .responseFailed,
            .responseFailed,
            .error,
            .unknown("future.event"),
            .error,
        ]
        for event in expected {
            #expect(await iterator.next() == event)
        }

        await transport.close()
        #expect(await iterator.next() == nil)
    }

    @Test("speaker echo candidate never interrupts and its committed input is deleted")
    func rejectedEchoDoesNotInterruptAssistant() async throws {
        let peer = RecordingPeerDriver()
        let detector = ControlledBargeInDetector()
        let transport = makeTransport(peer: peer, bargeInDetector: detector)
        let recorder = ProviderEventRecorder()
        let updates = await transport.eventUpdates()
        let recordingTask = Task {
            for await event in updates { await recorder.append(event) }
        }

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )
        await peer.emit(rawEvent(type: "session.created"))
        await peer.emit(rawEvent(type: "response.created"))
        await peer.emit(rawEvent(type: "output_audio_buffer.started"))
        #expect(await waitUntil { await recorder.events.count == 2 })

        await peer.emit(rawEvent(type: "input_audio_buffer.speech_started"))
        #expect(await waitUntil { await detector.confirmationRequestCount == 1 })
        #expect(await recorder.events == [.sessionCreated, .outputAudioStarted])
        #expect(await peer.sentData.count == 2)

        await detector.resolveConfirmation(false)
        await peer.emit(rawEvent(type: "input_audio_buffer.speech_stopped"))
        await peer.emit(rawCommittedInput(itemID: "echo-item"))

        #expect(await waitUntil { await peer.sentData.count == 3 })
        #expect(await recorder.events == [.sessionCreated, .outputAudioStarted])
        let expectedDelete = try OpenAIRealtimeWireEncoder
            .conversationItemDelete(itemID: "echo-item")
        let unexpectedCancel = try OpenAIRealtimeWireEncoder.responseCancel()
        let unexpectedClear = try OpenAIRealtimeWireEncoder.outputAudioBufferClear()
        #expect(await peer.sentData.last == expectedDelete)
        #expect(await peer.sentData.contains(unexpectedCancel) == false)
        #expect(await peer.sentData.contains(unexpectedClear) == false)

        let mapper = OpenAIRealtimeEventMapper()
        var semanticEvents: [OpenAIRealtimeMappedEvent] = []
        for event in await recorder.events {
            semanticEvents.append(contentsOf: await mapper.map(event))
        }
        #expect(
            semanticEvents.contains(.voice(.assistantInterrupted)) == false
        )

        await transport.close()
        _ = await recordingTask.result
    }

    @Test("completed generation with buffered playout clears audio without invalid cancel")
    func bufferedPlayoutBargeInDoesNotCancelCompletedResponse() async throws {
        let peer = RecordingPeerDriver()
        let detector = ControlledBargeInDetector()
        let transport = makeTransport(peer: peer, bargeInDetector: detector)
        let updates = await transport.eventUpdates()
        let recorder = ProviderEventRecorder()
        let recordingTask = Task {
            for await event in updates { await recorder.append(event) }
        }

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )
        await peer.emit(rawEvent(type: "session.created"))
        await peer.emit(rawEvent(type: "response.created"))
        await peer.emit(rawEvent(type: "output_audio_buffer.started"))
        await peer.emit(rawResponseDone(status: "completed"))
        await peer.emit(rawEvent(type: "input_audio_buffer.speech_started"))
        #expect(await waitUntil { await detector.confirmationRequestCount == 1 })

        await detector.resolveConfirmation(true)

        #expect(await waitUntil { await peer.sentData.count == 3 })
        let expectedClear = try OpenAIRealtimeWireEncoder.outputAudioBufferClear()
        let unexpectedCancel = try OpenAIRealtimeWireEncoder.responseCancel()
        #expect(await peer.sentData.last == expectedClear)
        #expect(await peer.sentData.contains(unexpectedCancel) == false)
        #expect(await waitUntil {
            await recorder.events.contains(.inputAudioSpeechStarted)
        })

        await transport.close()
        _ = await recordingTask.result
    }

    @Test("confirmed near-end speech cancels output then creates one response after commit")
    func confirmedBargeInControlsInterruptionAndResponse() async throws {
        let peer = RecordingPeerDriver()
        let detector = ControlledBargeInDetector()
        let transport = makeTransport(peer: peer, bargeInDetector: detector)
        let recorder = ProviderEventRecorder()
        let updates = await transport.eventUpdates()
        let recordingTask = Task {
            for await event in updates { await recorder.append(event) }
        }

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )
        await peer.emit(rawEvent(type: "session.created"))
        await peer.emit(rawEvent(type: "response.created"))
        await peer.emit(rawEvent(type: "output_audio_buffer.started"))
        await peer.emit(rawEvent(type: "input_audio_buffer.speech_started"))
        #expect(await waitUntil { await detector.confirmationRequestCount == 1 })

        await detector.resolveConfirmation(true)
        #expect(await waitUntil { await peer.sentData.count == 4 })
        #expect(await peer.sentData.suffix(2) == [
            try OpenAIRealtimeWireEncoder.responseCancel(),
            try OpenAIRealtimeWireEncoder.outputAudioBufferClear(),
        ])
        #expect(await waitUntil {
            await recorder.events.contains(.inputAudioSpeechStarted)
        })

        await peer.emit(rawEvent(type: "output_audio_buffer.cleared"))
        await peer.emit(rawEvent(type: "input_audio_buffer.speech_stopped"))
        await peer.emit(rawCommittedInput(itemID: "accepted-item"))

        for _ in 0 ..< 20 { await Task.yield() }
        #expect(await peer.sentData.count == 4)
        await peer.emit(rawResponseDone(status: "cancelled"))

        #expect(await waitUntil { await peer.sentData.count == 5 })
        let expectedResponse = try OpenAIRealtimeWireEncoder.responseCreate()
        #expect(await peer.sentData.last == expectedResponse)
        #expect(await recorder.events == [
            .sessionCreated,
            .outputAudioStarted,
            .inputAudioSpeechStarted,
            .outputAudioCleared,
            .inputAudioSpeechStopped,
        ])

        await transport.close()
        _ = await recordingTask.result
    }

    @Test("duplicate speech-start events do not restart one barge-in decision")
    func duplicateSpeechStartedKeepsOneBargeInDecision() async throws {
        let peer = RecordingPeerDriver()
        let detector = ControlledBargeInDetector()
        let transport = makeTransport(peer: peer, bargeInDetector: detector)

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )
        await peer.emit(rawEvent(type: "session.created"))
        await peer.emit(rawEvent(type: "response.created"))
        await peer.emit(rawEvent(type: "output_audio_buffer.started"))
        await peer.emit(rawEvent(type: "input_audio_buffer.speech_started"))
        #expect(await waitUntil { await detector.confirmationRequestCount == 1 })

        await peer.emit(rawEvent(type: "input_audio_buffer.speech_started"))
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(await detector.confirmationRequestCount == 1)
        await transport.close()
    }

    @Test("speech before playout cancels generation and waits for cancellation completion")
    func prePlayoutSpeechCancelsGenerationBeforeNewResponse() async throws {
        let peer = RecordingPeerDriver()
        let transport = makeTransport(peer: peer)
        let updates = await transport.eventUpdates()
        let recorder = ProviderEventRecorder()
        let recordingTask = Task {
            for await event in updates { await recorder.append(event) }
        }

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )
        await peer.emit(rawEvent(type: "session.created"))
        await peer.emit(rawEvent(type: "response.created"))
        await peer.emit(rawEvent(type: "input_audio_buffer.speech_started"))

        #expect(await waitUntil { await peer.sentData.count == 3 })
        let expectedCancel = try OpenAIRealtimeWireEncoder.responseCancel()
        #expect(await peer.sentData.last == expectedCancel)
        #expect(await waitUntil {
            await recorder.events.contains(.inputAudioSpeechStarted)
        })

        await peer.emit(rawEvent(type: "output_audio_buffer.started"))
        #expect(await waitUntil { await peer.sentData.count == 4 })
        let expectedClear = try OpenAIRealtimeWireEncoder.outputAudioBufferClear()
        #expect(await peer.sentData.last == expectedClear)
        #expect(await recorder.events == [
            .sessionCreated,
            .inputAudioSpeechStarted,
        ])

        await peer.emit(rawEvent(type: "input_audio_buffer.speech_stopped"))
        await peer.emit(rawCommittedInput(itemID: "pre-playout-input"))
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(await peer.sentData.count == 4)

        await peer.emit(rawResponseDone(status: "cancelled"))
        #expect(await waitUntil { await peer.sentData.count == 5 })
        let expectedResponse = try OpenAIRealtimeWireEncoder.responseCreate()
        #expect(await peer.sentData.last == expectedResponse)

        await transport.close()
        _ = await recordingTask.result
    }

    @Test("send failure before readiness publishes error, never readiness, and finishes")
    func sendFailureBeforeReadinessFailsHandshake() async throws {
        let audio = RecordingAudioController()
        let peer = RecordingPeerDriver(
            sendError: OpenAIRealtimePeerDriverError.dataSendFailed
        )
        let transport = makeTransport(audio: audio, peer: peer)
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )
        await peer.emit(rawEvent(type: "session.created"))

        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .error)
        #expect(await iterator.next() == nil)
        #expect(await peer.sentData.count == 0)
        #expect(await peer.closeCallCount == 1)
        #expect(await audio.deactivateCallCount == 1)
    }

    @Test("natural peer stream completion finishes the provider stream")
    func peerStreamCompletionFinishesProviderStream() async throws {
        let audio = RecordingAudioController()
        let peer = RecordingPeerDriver()
        let transport = makeTransport(audio: audio, peer: peer)
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )
        await peer.finishEventStream()

        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(await peer.closeCallCount == 1)
        #expect(await audio.deactivateCallCount == 1)
    }

    @Test("close cancels blocking signaling and pending connect without duplicate cleanup")
    func closeCancelsBlockingSignaling() async throws {
        let audio = RecordingAudioController()
        let peer = RecordingPeerDriver()
        let signaling = BlockingSignaling()
        let transport = makeTransport(audio: audio, peer: peer, signaling: signaling)
        let updates = await transport.eventUpdates()
        let connection = Task {
            try await transport.connect(
                clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .initial
            )
        }
        #expect(await waitUntil { await signaling.started })

        await transport.close()
        await transport.close()
        await signaling.release()
        await #expect(throws: CancellationError.self) {
            try await connection.value
        }
        #expect(await signaling.cancellationCount == 1)
        #expect(await peer.closeCallCount == 1)
        #expect(await audio.deactivateCallCount == 1)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test("close during handshake send cancels the consumer and does not publish stale events")
    func closeCancelsBlockingHandshakeSend() async throws {
        let audio = RecordingAudioController()
        let peer = RecordingPeerDriver(blockSend: true)
        let transport = makeTransport(audio: audio, peer: peer)
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )
        await peer.emit(rawEvent(type: "session.created"))
        #expect(await waitUntil { await peer.sendStarted })

        await transport.close()
        await peer.releaseSend()
        #expect(await waitUntil { await peer.sendCancellationCount == 1 })
        #expect(await peer.closeCallCount == 1)
        #expect(await audio.deactivateCallCount == 1)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test("close before connect is safe, idempotent, and permanently closes the stream")
    func closeBeforeConnectIsSafe() async throws {
        let audio = RecordingAudioController()
        let peer = RecordingPeerDriver()
        let transport = makeTransport(audio: audio, peer: peer)
        let updates = await transport.eventUpdates()

        await transport.close()
        await transport.close()
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(await peer.closeCallCount == 0)
        #expect(await audio.deactivateCallCount == 0)
        await #expect(throws: OpenAIWebRTCTransportError.closed) {
            try await transport.connect(
                clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .initial
            )
        }
    }

    @Test("duplicate connect on one fresh transport has no second side effects")
    func duplicateConnectIsRejected() async throws {
        let audio = RecordingAudioController()
        let peer = RecordingPeerDriver()
        let transport = makeTransport(audio: audio, peer: peer)
        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )

        await #expect(throws: OpenAIWebRTCTransportError.transportFailure) {
            try await transport.connect(
                clientSecret: try makeSecret(value: "second-token-marker", expiresAt: 200),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .reconnect
            )
        }
        #expect(await audio.activateCallCount == 1)
        #expect(await peer.prepareCallCount == 1)
        await transport.close()
    }

    @Test("reentrant connect while startup is blocked cannot replace the active generation")
    func reentrantConnectIsRejected() async throws {
        let audio = RecordingAudioController()
        let peer = RecordingPeerDriver()
        let signaling = BlockingSignaling()
        let transport = makeTransport(audio: audio, peer: peer, signaling: signaling)
        let first = Task {
            try await transport.connect(
                clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .initial
            )
        }
        #expect(await waitUntil { await signaling.started })

        await #expect(throws: OpenAIWebRTCTransportError.transportFailure) {
            try await transport.connect(
                clientSecret: try makeSecret(value: "second-token-marker", expiresAt: 200),
                configuration: OpenAIRealtimeConfiguration(),
                purpose: .reconnect
            )
        }
        await transport.close()
        await signaling.release()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        #expect(await audio.activateCallCount == 1)
        #expect(await peer.prepareCallCount == 1)
    }

    @Test("failure of initial response.create emits error after exactly one update")
    func secondHandshakeSendFailureIsRedactedAndTerminal() async throws {
        let audio = RecordingAudioController()
        let peer = RecordingPeerDriver(
            sendError: OpenAIRealtimePeerDriverError.dataSendFailed,
            failSendOn: 2
        )
        let transport = makeTransport(audio: audio, peer: peer)
        let updates = await transport.eventUpdates()

        try await transport.connect(
            clientSecret: try makeSecret(value: "token-marker", expiresAt: 200),
            configuration: OpenAIRealtimeConfiguration(),
            purpose: .initial
        )
        await peer.emit(rawEvent(type: "session.created"))

        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .error)
        #expect(await iterator.next() == nil)
        #expect(await peer.sentData.count == 1)
        #expect(await peer.closeCallCount == 1)
        #expect(await audio.deactivateCallCount == 1)
    }
}

private func makeTransport(
    clock: any OpenAIRealtimeClock = TestClock(now: Date(timeIntervalSince1970: 100)),
    permission: any OpenAIRealtimeMicrophonePermissionClient = RecordingPermission(),
    audio: any OpenAIRealtimeAudioSessionController = RecordingAudioController(),
    peer: any OpenAIRealtimePeerDriver = RecordingPeerDriver(),
    signaling: any OpenAIRealtimeSDPSignaling = RecordingSignaling(),
    bargeInDetector: any OpenAIRealtimeBargeInDetecting = NeverConfirmBargeInDetector()
) -> OpenAIWebRTCTransport {
    OpenAIWebRTCTransport(
        clock: clock,
        permission: permission,
        audioSession: audio,
        peerDriver: peer,
        signaling: signaling,
        bargeInDetector: bargeInDetector
    )
}

private func rawEvent(type: String) -> Data {
    Data("{\"type\":\"\(type)\"}".utf8)
}

private func rawResponseDone(status: String) -> Data {
    Data("{\"type\":\"response.done\",\"response\":{\"status\":\"\(status)\"}}".utf8)
}

private func rawCommittedInput(itemID: String) -> Data {
    Data(
        "{\"type\":\"input_audio_buffer.committed\",\"item_id\":\"\(itemID)\"}".utf8
    )
}

private func makeSecret(
    value: String,
    expiresAt timestamp: TimeInterval
) throws -> OpenAIRealtimeClientSecret {
    try OpenAIRealtimeClientSecret(
        value: value,
        expiresAt: Date(timeIntervalSince1970: timestamp)
    )
}

private func thrownTransportError(
    _ operation: () async throws -> Void
) async -> OpenAIWebRTCTransportError {
    do {
        try await operation()
        Issue.record("Expected transport operation to throw")
        return .transportFailure
    } catch let error as OpenAIWebRTCTransportError {
        return error
    } catch {
        Issue.record("Unexpected transport error: \(error)")
        return .transportFailure
    }
}

private func assertRedacted(
    _ error: OpenAIWebRTCTransportError,
    markers: [String]
) {
    for diagnostic in [String(describing: error), String(reflecting: error)] {
        for marker in markers {
            #expect(!diagnostic.contains(marker))
        }
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< 256 {
        if await condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

private actor Trace {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor ProviderEventRecorder {
    private(set) var events: [OpenAIRealtimeProviderEvent] = []

    func append(_ event: OpenAIRealtimeProviderEvent) {
        events.append(event)
    }
}

private actor NeverConfirmBargeInDetector: OpenAIRealtimeBargeInDetecting {
    func assistantOutputStarted() {}
    func assistantOutputEnded() {}
    func confirmInterruption() async -> Bool { false }
    func rejectedInputEnded() {}
}

private actor ControlledBargeInDetector: OpenAIRealtimeBargeInDetecting {
    private let decisions: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation
    private(set) var confirmationRequestCount = 0

    init() {
        let pair = AsyncStream<Bool>.makeStream(
            of: Bool.self,
            bufferingPolicy: .unbounded
        )
        decisions = pair.stream
        continuation = pair.continuation
    }

    func assistantOutputStarted() {}
    func assistantOutputEnded() {}
    func rejectedInputEnded() {}

    func confirmInterruption() async -> Bool {
        confirmationRequestCount += 1
        for await decision in decisions {
            return decision
        }
        return false
    }

    func resolveConfirmation(_ decision: Bool) {
        continuation.yield(decision)
    }
}

private actor TestClock: OpenAIRealtimeClock {
    private var value: Date
    private let trace: Trace?

    init(now: Date, trace: Trace? = nil) {
        self.value = now
        self.trace = trace
    }

    func now() async -> Date {
        await trace?.append("clock")
        return value
    }

    func setNow(_ now: Date) {
        value = now
    }
}

private actor RecordingPermission: OpenAIRealtimeMicrophonePermissionClient {
    private(set) var callCount = 0
    private let trace: Trace?
    private let error: OpenAIRealtimeMicrophonePermissionError?
    private let onAuthorize: (@Sendable () async -> Void)?

    init(
        trace: Trace? = nil,
        error: OpenAIRealtimeMicrophonePermissionError? = nil,
        onAuthorize: (@Sendable () async -> Void)? = nil
    ) {
        self.trace = trace
        self.error = error
        self.onAuthorize = onAuthorize
    }

    func authorize() async throws(OpenAIRealtimeMicrophonePermissionError) {
        callCount += 1
        await trace?.append("permission")
        await onAuthorize?()
        if let error { throw error }
    }
}

private actor RecordingAudioController: OpenAIRealtimeAudioSessionController {
    private(set) var activateCallCount = 0
    private(set) var deactivateCallCount = 0
    private let trace: Trace?
    private let error: (any Error)?

    init(trace: Trace? = nil, error: (any Error)? = nil) {
        self.trace = trace
        self.error = error
    }

    func activate() async throws {
        activateCallCount += 1
        await trace?.append("audio.activate")
        if let error { throw error }
    }

    func deactivate() async {
        deactivateCallCount += 1
        await trace?.append("audio.deactivate")
    }
}

private actor RecordingPeerDriver: OpenAIRealtimePeerDriver {
    private(set) var prepareCallCount = 0
    private(set) var createLocalOfferCallCount = 0
    private(set) var closeCallCount = 0
    private(set) var eventUpdatesCallCount = 0
    private(set) var sentData: [Data] = []
    private(set) var sendStarted = false
    private(set) var sendCancellationCount = 0
    private(set) var receivedAnswer: String?
    private let trace: Trace?
    private let offer: String
    private let prepareError: (any Error)?
    private let offerError: (any Error)?
    private let answerError: (any Error)?
    private let sendError: (any Error)?
    private let failSendOn: Int?
    private let blockSend: Bool
    private let blockSendOn: Int?
    private let eventStream: AsyncStream<Data>
    private let eventContinuation: AsyncStream<Data>.Continuation
    private var sendCallCount = 0
    private var pendingSend: CheckedContinuation<Void, any Error>?

    init(
        trace: Trace? = nil,
        offer: String = "offer-marker",
        error: (any Error)? = nil,
        answerError: (any Error)? = nil,
        sendError: (any Error)? = nil,
        failSendOn: Int? = nil,
        blockSend: Bool = false,
        blockSendOn: Int? = nil
    ) {
        self.trace = trace
        self.offer = offer
        self.prepareError = nil
        self.offerError = error
        self.answerError = answerError
        self.sendError = sendError
        self.failSendOn = failSendOn ?? (sendError == nil ? nil : 1)
        self.blockSend = blockSend
        self.blockSendOn = blockSendOn
        let stream = AsyncStream<Data>.makeStream(
            of: Data.self,
            bufferingPolicy: .unbounded
        )
        self.eventStream = stream.stream
        self.eventContinuation = stream.continuation
    }

    func prepare() async throws {
        prepareCallCount += 1
        await trace?.append("peer.prepare")
        if let prepareError { throw prepareError }
    }

    func createLocalOffer() async throws -> String {
        createLocalOfferCallCount += 1
        await trace?.append("peer.offer")
        if let offerError { throw offerError }
        return offer
    }

    func setRemoteAnswer(_ answerSDP: String) async throws {
        receivedAnswer = answerSDP
        await trace?.append("peer.\(answerSDP)")
        if let answerError { throw answerError }
    }

    func send(_ data: Data) async throws {
        sendCallCount += 1
        if blockSend && (blockSendOn == nil || blockSendOn == sendCallCount) {
            sendStarted = true
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    pendingSend = continuation
                }
            }, onCancel: {
                Task { await self.cancelPendingSend() }
            })
            return
        }
        if let sendError, failSendOn == sendCallCount { throw sendError }
        sentData.append(data)
    }

    func releaseSend() {
        pendingSend?.resume()
        pendingSend = nil
    }

    private func cancelPendingSend() {
        sendCancellationCount += 1
        pendingSend?.resume(throwing: CancellationError())
        pendingSend = nil
    }

    func eventUpdates() async -> AsyncStream<Data> {
        eventUpdatesCallCount += 1
        return eventStream
    }

    func emit(_ data: Data) {
        eventContinuation.yield(data)
    }

    func finishEventStream() {
        eventContinuation.finish()
    }

    func close() async {
        closeCallCount += 1
        await trace?.append("peer.close")
    }
}

private actor RecordingSignaling: OpenAIRealtimeSDPSignaling {
    private(set) var callCount = 0
    private(set) var receivedOffer: String?
    private(set) var receivedToken: String?
    private let trace: Trace?
    private let answer: String
    private let error: (any Error)?

    init(
        trace: Trace? = nil,
        answer: String = "answer-marker",
        error: (any Error)? = nil
    ) {
        self.trace = trace
        self.answer = answer
        self.error = error
    }

    func exchange(
        offerSDP: String,
        clientSecret: OpenAIRealtimeClientSecret
    ) async throws -> String {
        callCount += 1
        receivedOffer = offerSDP
        receivedToken = clientSecret.value
        await trace?.append("signaling.\(offerSDP).\(clientSecret.value)")
        if let error { throw error }
        return answer
    }
}

private actor BlockingSignaling: OpenAIRealtimeSDPSignaling {
    private(set) var started = false
    private(set) var cancellationCount = 0
    private var pendingExchange: CheckedContinuation<String, any Error>?

    func exchange(
        offerSDP _: String,
        clientSecret _: OpenAIRealtimeClientSecret
    ) async throws -> String {
        started = true
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pendingExchange = continuation
            }
        }, onCancel: {
            Task { await self.cancelPendingExchange() }
        })
    }

    func release() {
        pendingExchange?.resume(throwing: CancellationError())
        pendingExchange = nil
    }

    private func cancelPendingExchange() {
        cancellationCount += 1
        pendingExchange?.resume(throwing: CancellationError())
        pendingExchange = nil
    }
}
