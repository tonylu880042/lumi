import Foundation
import LumiApplication
import LumiDomain
import Testing

@Suite("Assistant session coordinator", .serialized)
struct AssistantSessionCoordinatorTests {
    @Test("ends an active session only after confirmed home arrival")
    func endSessionWaitsForConfirmedHomeArrival() async throws {
        let hardware = TestHardware()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: TestIdentity(),
            voice: TestVoice()
        )
        try await coordinator.confirmPresence(direction: .center)
        await hardware.holdReturnHome()

        let operation = Task { try await coordinator.endSession() }
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        #expect(await coordinator.state == .detected(direction: .center))
        await hardware.completeReturnHome()
        #expect(try await operation.value == .idle)
        #expect(await coordinator.state == .idle)
    }

    @Test("rejects ending an idle session before any port side effect")
    func endIdlePreflightHasNoSideEffects() async throws {
        let hardware = TestHardware()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: TestIdentity(),
            voice: voice
        )

        do {
            _ = try await coordinator.endSession()
            Issue.record("Expected endSession from idle to throw")
        } catch let error as AssistantStateTransitionError {
            #expect(error.sourceState == .idle)
            #expect(error.event == .sessionEnded)
        }

        #expect(await coordinator.state == .idle)
        #expect(await voice.stopCallCount == 0)
        #expect(await hardware.stopCallCount == 0)
        #expect(await hardware.returnHomeCallCount == 0)
    }

    @Test("ends speaking after home confirmation and clears session context last")
    func endSpeakingClearsContextAfterHomeConfirmation() async throws {
        let log = TestCallLog()
        let hardware = TestHardware(log: log)
        let identity = TestIdentity()
        let voice = TestVoice(log: log)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterSpeaking(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voice: voice,
            result: .unknown
        )

        await voice.emit(.failure)
        #expect(await waitUntil { await coordinator.voiceRequiresRetry })
        var updates = (await coordinator.stateUpdates()).makeAsyncIterator()
        #expect(await updates.next() == .speaking)
        await hardware.holdReturnHome()

        let end = Task { try await coordinator.endSession() }
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        #expect(await coordinator.state == .speaking)
        #expect(await coordinator.recognitionResult == .unknown)
        #expect(await coordinator.voiceRequiresRetry)
        #expect(await log.entries == [.voiceStop, .returnHome])

        await hardware.completeReturnHome()
        #expect(try await end.value == .idle)
        #expect(await updates.next() == .idle)
        #expect(await coordinator.state == .idle)
        #expect(await coordinator.recognitionResult == nil)
        #expect(await coordinator.voiceRequiresRetry == false)
    }

    @Test("ending a rotating session stops movement without recovering to detected")
    func endRotatingCancelsOrientationWithoutDetectedRecovery() async throws {
        let log = TestCallLog()
        let hardware = TestHardware(log: log)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: TestIdentity(),
            voice: TestVoice(log: log)
        )
        try await coordinator.confirmPresence(direction: .left)
        let orientation = Task { try await coordinator.beginOrientation() }
        #expect(await waitUntil { await hardware.hasPendingRotation })
        #expect(await coordinator.state == .rotating)

        await hardware.holdReturnHome()
        let end = Task { try await coordinator.endSession() }
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        #expect(await coordinator.state == .rotating)
        #expect(await log.entries == [.voiceStop, .hardwareStop, .returnHome])

        await hardware.completeRotation()
        await hardware.completeReturnHome()
        await #expect(throws: CancellationError.self) {
            try await orientation.value
        }
        #expect(try await end.value == .idle)
        #expect(await coordinator.state == .idle)
        #expect(await hardware.stopCallCount == 1)
    }

    @Test("duplicate end requests are rejected while home is pending")
    func duplicateEndIsRejectedWithoutDuplicateSideEffects() async throws {
        let log = TestCallLog()
        let hardware = TestHardware(log: log)
        let voice = TestVoice(log: log)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: TestIdentity(),
            voice: voice
        )
        try await coordinator.confirmPresence(direction: .center)
        await hardware.holdReturnHome()

        let first = Task { try await coordinator.endSession() }
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        await #expect(throws: AssistantSessionCoordinatorError.endSessionInProgress) {
            try await coordinator.endSession()
        }
        #expect(await voice.stopCallCount == 1)
        #expect(await hardware.returnHomeCallCount == 1)
        #expect(await log.entries == [.voiceStop, .returnHome])

        await hardware.completeReturnHome()
        #expect(try await first.value == .idle)
    }

    @Test("return-home failure retains context and permits a retry")
    func returnHomeFailureRetainsContextAndCanRetry() async throws {
        let log = TestCallLog()
        let hardware = TestHardware(log: log)
        let identity = TestIdentity()
        let voice = TestVoice(log: log)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let memberID = try MemberID(rawValue: "M123")
        let confidence = try RecognitionConfidence(value: 0.9)
        let expected = RecognitionResult.known(memberID: memberID, confidence: confidence)
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: expected
        )

        await hardware.holdReturnHome()
        let end = Task { try await coordinator.endSession() }
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        await hardware.failPendingReturnHome(with: HomeFailure.injected)
        await #expect(throws: HomeFailure.injected) {
            try await end.value
        }
        #expect(await coordinator.state == .greeting)
        #expect(await coordinator.recognitionResult == expected)
        #expect(await coordinator.voiceRequiresRetry == false)
        #expect(await hardware.stopCallCount == 1)
        #expect(await log.entries == [.voiceStop, .returnHome, .hardwareStop])

        let retry = Task { try await coordinator.endSession() }
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        await hardware.completeReturnHome()
        #expect(try await retry.value == .idle)
        #expect(await coordinator.recognitionResult == nil)
    }

    @Test("return-home cancellation stops hardware, retains context, and permits retry")
    func returnHomeCancellationRetainsContextAndCanRetry() async throws {
        let log = TestCallLog()
        let hardware = TestHardware(log: log)
        let identity = TestIdentity()
        let voice = TestVoice(log: log)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .unknown
        )

        await hardware.holdReturnHome()
        let canceled = Task { try await coordinator.endSession() }
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        canceled.cancel()
        await #expect(throws: CancellationError.self) {
            try await canceled.value
        }
        #expect(await coordinator.state == .greeting)
        #expect(await coordinator.recognitionResult == .unknown)
        #expect(await hardware.stopCallCount == 1)

        let retry = Task { try await coordinator.endSession() }
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        await hardware.completeReturnHome()
        #expect(try await retry.value == .idle)
        #expect(await coordinator.recognitionResult == nil)
    }

    @Test("ending recognition cancels stale identity completion without repopulating context")
    func staleIdentityCompletionIsIgnoredDuringEnd() async throws {
        let log = TestCallLog()
        let hardware = TestHardware(log: log)
        let identity = TestIdentity()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: TestVoice(log: log)
        )
        try await enterRecognizing(coordinator: coordinator, hardware: hardware)

        let recognition = Task { try await coordinator.recognizeVisitor() }
        #expect(await waitUntil { await identity.hasPendingRequest })
        await hardware.holdReturnHome()
        let end = Task { try await coordinator.endSession() }
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        await #expect(throws: CancellationError.self) {
            try await recognition.value
        }
        #expect(await coordinator.state == .recognizing)
        #expect(await coordinator.recognitionResult == nil)
        await identity.complete(with: .unknown)

        await hardware.completeReturnHome()
        #expect(try await end.value == .idle)
        #expect(await coordinator.recognitionResult == nil)
    }

    @Test("ending voice startup cancels it without a second voice stop or retry flag")
    func staleVoiceStartupIsIgnoredDuringEnd() async throws {
        let log = TestCallLog()
        let hardware = TestHardware(log: log)
        let identity = TestIdentity()
        let voice = TestVoice(log: log)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .unknown
        )

        let startup = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        await hardware.holdReturnHome()
        let end = Task { try await coordinator.endSession() }
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        await #expect(throws: CancellationError.self) {
            try await startup.value
        }
        #expect(await voice.stopCallCount == 1)
        #expect(await coordinator.voiceRequiresRetry == false)
        await hardware.completeReturnHome()
        #expect(try await end.value == .idle)
    }

    @Test("ending during member-address lookup prevents stale voice startup")
    func staleVoiceStartupCannotStartAfterResolverRelease() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = ImmediateRecordingVoice()
        let resolver = CancellableMemberAddressResolver()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice,
            memberAddressResolver: { memberID in
                await resolver.resolve(memberID)
            }
        )
        let memberID = try MemberID(rawValue: "resolver-race")
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .known(
                memberID: memberID,
                confidence: try RecognitionConfidence(value: 0.9)
            )
        )

        let startup = Task { try await coordinator.startVoiceSession() }
        await resolver.waitForLookup()
        await hardware.holdReturnHome()
        let end = Task { try await coordinator.endSession() }
        #expect(await waitUntil { await hardware.returnHomeCallCount == 1 })
        #expect(await waitUntil { await resolver.cancellationObserved })

        await resolver.release()
        await #expect(throws: CancellationError.self) {
            try await startup.value
        }
        #expect(await voice.startCallCount == 0)
        #expect(await coordinator.state == .greeting)

        await hardware.completeReturnHome()
        #expect(try await end.value == .idle)
        #expect(await coordinator.state == .idle)
        #expect(await voice.stopCallCount == 1)
    }

    @Test("queued voice events from the ended generation cannot mutate state")
    func staleVoiceEventsAreIgnoredDuringEnd() async throws {
        let log = TestCallLog()
        let hardware = TestHardware(log: log)
        let identity = TestIdentity()
        let voice = TestVoice(log: log)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterSpeaking(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voice: voice,
            result: .unknown
        )

        await hardware.holdReturnHome()
        let end = Task { try await coordinator.endSession() }
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        await voice.emitAfterStop(.failure)
        await Task.yield()
        #expect(await coordinator.state == .speaking)
        #expect(await coordinator.voiceRequiresRetry == false)

        await hardware.completeReturnHome()
        #expect(try await end.value == .idle)
    }

    @Test("starts idle and streams each transition to two independent observers")
    func startsIdleAndPublishesTransitions() async throws {
        let hardware = TestHardware()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: TestIdentity(),
            voice: TestVoice()
        )
        var first = (await coordinator.stateUpdates()).makeAsyncIterator()
        var second = (await coordinator.stateUpdates()).makeAsyncIterator()

        #expect(await coordinator.state == .idle)
        #expect(await first.next() == .idle)
        #expect(await second.next() == .idle)

        #expect(try await coordinator.confirmPresence(direction: .left) == .detected(direction: .left))
        #expect(await first.next() == .detected(direction: .left))
        #expect(await second.next() == .detected(direction: .left))

        let operation = Task { try await coordinator.beginOrientation() }
        #expect(await first.next() == .rotating)
        #expect(await second.next() == .rotating)

        await hardware.completeRotation()
        #expect(try await operation.value == .recognizing)
        #expect(await first.next() == .recognizing)
        #expect(await second.next() == .recognizing)
    }

    @Test("maps every direction to an absolute target and waits for arrival")
    func mapsDirectionToAbsoluteTarget() async throws {
        for (direction, degrees) in [
            (PresenceDirection.left, -90.0),
            (PresenceDirection.center, 0.0),
            (PresenceDirection.right, 90.0),
        ] {
            let hardware = TestHardware()
            let coordinator = AssistantSessionCoordinator(
                hardware: hardware,
                identity: TestIdentity(),
                voice: TestVoice()
            )
            try await coordinator.confirmPresence(direction: direction)
            let operation = Task { try await coordinator.beginOrientation() }

            let target = try RotationAngle(degrees: degrees)
            guard await waitUntil({ await hardware.rotationTargets == [target] }) else {
                Issue.record("Timed out waiting for the rotation target")
                return
            }
            #expect(await coordinator.state == .rotating)
            #expect(await hardware.rotationTargets == [target])

            await hardware.completeRotation()
            #expect(try await operation.value == .recognizing)
            #expect(await coordinator.state == .recognizing)
        }
    }

    @Test("rejects duplicate and reentrant commands without replacing the active rotation")
    func rejectsDuplicateAndReentrantCommands() async throws {
        let hardware = TestHardware()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: TestIdentity(),
            voice: TestVoice()
        )
        try await coordinator.confirmPresence(direction: .right)

        let first = Task { try await coordinator.beginOrientation() }
        let target = try RotationAngle(degrees: 90)
        guard await waitUntil({ await hardware.rotationTargets == [target] }) else {
            Issue.record("Timed out waiting for the rotation target")
            return
        }

        do {
            _ = try await coordinator.beginOrientation()
            Issue.record("Expected a duplicate beginOrientation call to throw")
        } catch let error as AssistantStateTransitionError {
            #expect(error.sourceState == .rotating)
            #expect(error.event == .beginOrientation)
        }

        do {
            _ = try await coordinator.confirmPresence(direction: .left)
            Issue.record("Expected a reentrant confirmPresence call to throw")
        } catch let error as AssistantStateTransitionError {
            #expect(error.sourceState == .rotating)
            #expect(error.event == .personConfirmed(direction: .left))
        }

        #expect(await hardware.rotationTargets == [target])
        #expect(await coordinator.state == .rotating)
        await hardware.completeRotation()
        #expect(try await first.value == .recognizing)
    }

    @Test("stops failed orientation, restores direction, and permits retry")
    func restoresDirectionAfterHardwareFailureAndRetries() async throws {
        let hardware = TestHardware()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: TestIdentity(),
            voice: TestVoice()
        )
        var updates = (await coordinator.stateUpdates()).makeAsyncIterator()
        #expect(await updates.next() == .idle)
        let failure = HardwareFailure.immediate
        try await coordinator.confirmPresence(direction: .right)
        #expect(await updates.next() == .detected(direction: .right))

        let operation = Task { try await coordinator.beginOrientation() }
        let target = try RotationAngle(degrees: 90)
        guard await waitUntil({ await hardware.rotationTargets == [target] }) else {
            Issue.record("Timed out waiting for the failed rotation target")
            return
        }
        guard await waitUntil({ await hardware.hasPendingRotation }) else {
            Issue.record("Timed out waiting for the pending failed rotation")
            return
        }
        #expect(await updates.next() == .rotating)
        await hardware.failPendingRotation(with: failure)
        do {
            _ = try await operation.value
            Issue.record("Expected the hardware failure to be rethrown")
        } catch let error as HardwareFailure {
            #expect(error == failure)
        }

        #expect(await updates.next() == .detected(direction: .right))
        #expect(await hardware.stopCallCount == 1)
        #expect(await coordinator.state == .detected(direction: .right))

        let retry = Task { try await coordinator.beginOrientation() }
        guard await waitUntil({ await hardware.rotationTargets == [target, target] }) else {
            Issue.record("Timed out waiting for the retry rotation target")
            return
        }
        #expect(await coordinator.state == .rotating)
        await hardware.completeRotation()
        #expect(try await retry.value == .recognizing)
        #expect(await hardware.stopCallCount == 1)
    }

    @Test("stops cancelled orientation, preserves cancellation, and ignores late completion")
    func restoresDirectionAfterCancellationAndIgnoresLateCompletion() async throws {
        let hardware = TestHardware()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: TestIdentity(),
            voice: TestVoice()
        )
        var updates = (await coordinator.stateUpdates()).makeAsyncIterator()
        #expect(await updates.next() == .idle)
        try await coordinator.confirmPresence(direction: .left)
        #expect(await updates.next() == .detected(direction: .left))

        let canceled = Task { try await coordinator.beginOrientation() }
        let target = try RotationAngle(degrees: -90)
        guard await waitUntil({ await hardware.rotationTargets == [target] }) else {
            Issue.record("Timed out waiting for the cancelled rotation target")
            return
        }
        #expect(await updates.next() == .rotating)
        canceled.cancel()
        await #expect(throws: CancellationError.self) {
            try await canceled.value
        }

        #expect(await hardware.stopCallCount == 1)
        #expect(await coordinator.state == .detected(direction: .left))
        #expect(await updates.next() == .detected(direction: .left))
        await hardware.completeRotation()
        #expect(await coordinator.state == .detected(direction: .left))

        let retry = Task { try await coordinator.beginOrientation() }
        guard await waitUntil({ await hardware.rotationTargets == [target, target] }) else {
            Issue.record("Timed out waiting for the retry rotation target")
            return
        }
        await hardware.completeRotation()
        #expect(try await retry.value == .recognizing)
    }

    @Test("resolves a known visitor exactly and enters greeting")
    func recognizesKnownVisitor() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: TestVoice()
        )
        try await enterRecognizing(
            coordinator: coordinator,
            hardware: hardware
        )

        let memberID = try MemberID(rawValue: "M123")
        let confidence = try RecognitionConfidence(value: 0.93)
        let expected = RecognitionResult.known(
            memberID: memberID,
            confidence: confidence
        )
        let operation = Task { try await coordinator.recognizeVisitor() }
        guard await waitUntil({ await identity.hasPendingRequest }) else {
            Issue.record("Timed out waiting for identity recognition")
            return
        }

        await identity.complete(with: expected)

        #expect(try await operation.value == expected)
        #expect(await coordinator.state == .greeting)
        #expect(await coordinator.recognitionResult == expected)
        #expect(await identity.callCount == 1)
    }

    @Test("resolves an unknown visitor and enters greeting without identity details")
    func recognizesUnknownVisitor() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: TestVoice()
        )
        try await enterRecognizing(
            coordinator: coordinator,
            hardware: hardware
        )

        let operation = Task { try await coordinator.recognizeVisitor() }
        guard await waitUntil({ await identity.hasPendingRequest }) else {
            Issue.record("Timed out waiting for identity recognition")
            return
        }

        await identity.complete(with: .unknown)

        #expect(try await operation.value == .unknown)
        #expect(await coordinator.state == .greeting)
        #expect(await coordinator.recognitionResult == .unknown)
        #expect(await identity.callCount == 1)
    }

    @Test("degrades non-cancellation identity failures to unknown greeting")
    func degradesIdentityFailureToUnknown() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: TestVoice()
        )
        try await enterRecognizing(
            coordinator: coordinator,
            hardware: hardware
        )

        let operation = Task { try await coordinator.recognizeVisitor() }
        guard await waitUntil({ await identity.hasPendingRequest }) else {
            Issue.record("Timed out waiting for identity recognition")
            return
        }

        await identity.fail(with: TestIdentityError.adapterFailure)

        #expect(try await operation.value == .unknown)
        #expect(await coordinator.state == .greeting)
        #expect(await coordinator.recognitionResult == .unknown)
        #expect(await identity.callCount == 1)
    }

    @Test("propagates cancellation and leaves recognizing state and result unchanged")
    func cancellationLeavesRecognitionUnchanged() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: TestVoice()
        )
        try await enterRecognizing(
            coordinator: coordinator,
            hardware: hardware
        )

        let operation = Task { try await coordinator.recognizeVisitor() }
        guard await waitUntil({ await identity.hasPendingRequest }) else {
            Issue.record("Timed out waiting for identity recognition")
            return
        }

        operation.cancel()
        await #expect(throws: CancellationError.self) {
            try await operation.value
        }

        #expect(await coordinator.state == .recognizing)
        #expect(await coordinator.recognitionResult == nil)
        #expect(await identity.callCount == 1)

        let retry = Task { try await coordinator.recognizeVisitor() }
        guard await waitUntil({ await identity.hasPendingRequest }) else {
            Issue.record("Timed out waiting for the retry recognition")
            return
        }
        #expect(await identity.callCount == 2)

        await identity.complete(with: .unknown)

        #expect(try await retry.value == .unknown)
        #expect(await coordinator.state == .greeting)
        #expect(await coordinator.recognitionResult == .unknown)
    }

    @Test("rejects duplicate recognition without a second port call")
    func rejectsDuplicateRecognition() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: TestVoice()
        )
        try await enterRecognizing(
            coordinator: coordinator,
            hardware: hardware
        )

        let first = Task { try await coordinator.recognizeVisitor() }
        guard await waitUntil({ await identity.hasPendingRequest }) else {
            Issue.record("Timed out waiting for identity recognition")
            return
        }

        do {
            _ = try await coordinator.recognizeVisitor()
            Issue.record("Expected duplicate recognition to throw")
        } catch let error as AssistantSessionCoordinatorError {
            #expect(error == .identityRecognitionInProgress)
        }

        #expect(await identity.callCount == 1)
        #expect(await coordinator.state == .recognizing)

        await identity.complete(with: .unknown)
        #expect(try await first.value == .unknown)
        #expect(await coordinator.state == .greeting)
    }

    @Test("rejects recognition outside recognizing with the reducer transition error")
    func rejectsRecognitionOutsideRecognizing() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: TestVoice()
        )

        do {
            _ = try await coordinator.recognizeVisitor()
            Issue.record("Expected recognition from idle to throw")
        } catch let error as AssistantStateTransitionError {
            #expect(error.sourceState == .idle)
            #expect(error.event == .identityResolved(.unknown))
        }

        #expect(await coordinator.state == .idle)
        #expect(await coordinator.recognitionResult == nil)
        #expect(await identity.callCount == 0)
    }

    @Test("passes privacy-safe known and unknown voice contexts")
    func startsVoiceWithMappedContext() async throws {
        let knownHardware = TestHardware()
        let knownIdentity = TestIdentity()
        let knownVoice = TestVoice()
        let knownCoordinator = AssistantSessionCoordinator(
            hardware: knownHardware,
            identity: knownIdentity,
            voice: knownVoice
        )
        let memberID = try MemberID(rawValue: "M123")
        let confidence = try RecognitionConfidence(value: 0.93)
        try await enterGreeting(
            coordinator: knownCoordinator,
            hardware: knownHardware,
            identity: knownIdentity,
            result: .known(memberID: memberID, confidence: confidence)
        )

        let knownStart = Task { try await knownCoordinator.startVoiceSession() }
        await knownVoice.waitForStartRequest()
        #expect(await knownVoice.startContexts == [.returningMember])
        #expect(await knownVoice.startDirections == [.general])
        await knownVoice.completeStart()
        #expect(try await knownStart.value == .speaking)

        let unknownHardware = TestHardware()
        let unknownIdentity = TestIdentity()
        let unknownVoice = TestVoice()
        let unknownCoordinator = AssistantSessionCoordinator(
            hardware: unknownHardware,
            identity: unknownIdentity,
            voice: unknownVoice
        )
        try await enterGreeting(
            coordinator: unknownCoordinator,
            hardware: unknownHardware,
            identity: unknownIdentity,
            result: .unknown
        )

        let unknownStart = Task { try await unknownCoordinator.startVoiceSession() }
        await unknownVoice.waitForStartRequest()
        #expect(await unknownVoice.startContexts == [.visitor])
        #expect(await unknownVoice.startDirections == [.general])
        await unknownVoice.completeStart()
        #expect(try await unknownStart.value == .speaking)
    }

    @Test("maps the approved tony identity to a spoken label at the voice boundary")
    func startsVoiceWithApprovedTonySpokenLabel() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let memberID = try MemberID(rawValue: "tony")
        let memberAddress = try VoiceMemberAddress(spokenLabel: "tony")
        let debugResolver: @Sendable (MemberID) -> VoiceMemberAddress? = { candidate in
            candidate == memberID ? memberAddress : nil
        }
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice,
            memberAddressResolver: debugResolver
        )
        let confidence = try RecognitionConfidence(value: 0.93)
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .known(memberID: memberID, confidence: confidence)
        )

        let start = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()

        #expect(await voice.startContexts == [.returningMember])
        #expect(await voice.startMemberAddresses == [memberAddress])
        await voice.completeStart()
        #expect(try await start.value == .speaking)
    }

    @Test("keeps an unlabelled known member anonymous in the voice context")
    func startsVoiceWithoutSpokenLabelByDefault() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let memberID = try MemberID(rawValue: "unmapped-member")
        let confidence = try RecognitionConfidence(value: 0.93)
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .known(memberID: memberID, confidence: confidence)
        )

        let start = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()

        #expect(await voice.startContexts == [.returningMember])
        #expect(await voice.startMemberAddresses == [nil])
        await voice.completeStart()
        #expect(try await start.value == .speaking)
    }

    @Test("passes explicit directions for known and unknown visitors without identity payload")
    func startsVoiceWithExplicitDirections() async throws {
        let knownHardware = TestHardware()
        let knownIdentity = TestIdentity()
        let knownVoice = TestVoice()
        let knownCoordinator = AssistantSessionCoordinator(
            hardware: knownHardware,
            identity: knownIdentity,
            voice: knownVoice
        )
        let memberID = try MemberID(rawValue: "M-direction-known")
        try await enterGreeting(
            coordinator: knownCoordinator,
            hardware: knownHardware,
            identity: knownIdentity,
            result: .known(
                memberID: memberID,
                confidence: try RecognitionConfidence(value: 0.94)
            )
        )

        let knownStart = Task {
            try await knownCoordinator.startVoiceSession(
                direction: .preWorkoutReminder
            )
        }
        await knownVoice.waitForStartRequest()
        #expect(await knownVoice.startContexts == [.returningMember])
        #expect(await knownVoice.startDirections == [.preWorkoutReminder])
        #expect(
            String(reflecting: VoiceConversationDirection.preWorkoutReminder)
                .contains(memberID.rawValue) == false
        )
        await knownVoice.completeStart()
        #expect(try await knownStart.value == .speaking)

        let unknownHardware = TestHardware()
        let unknownIdentity = TestIdentity()
        let unknownVoice = TestVoice()
        let unknownCoordinator = AssistantSessionCoordinator(
            hardware: unknownHardware,
            identity: unknownIdentity,
            voice: unknownVoice
        )
        try await enterGreeting(
            coordinator: unknownCoordinator,
            hardware: unknownHardware,
            identity: unknownIdentity,
            result: .unknown
        )

        let unknownStart = Task {
            try await unknownCoordinator.startVoiceSession(
                direction: .postWorkoutReview
            )
        }
        await unknownVoice.waitForStartRequest()
        #expect(await unknownVoice.startContexts == [.visitor])
        #expect(await unknownVoice.startDirections == [.postWorkoutReview])
        await unknownVoice.completeStart()
        #expect(try await unknownStart.value == .speaking)
    }

    @Test("does not publish speaking or consume events before voice startup is ready")
    func voiceStartupWaitsForReadyBeforeTransitionAndConsumption() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .unknown
        )
        var updates = (await coordinator.stateUpdates()).makeAsyncIterator()
        #expect(await updates.next() == .greeting)

        let start = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        #expect(await coordinator.state == .greeting)
        await voice.emit(.userSpeechStarted)
        #expect(await coordinator.state == .greeting)

        await voice.completeStart()
        #expect(try await start.value == .speaking)
        #expect(await updates.next() == .speaking)
        await voice.emit(.userSpeechStarted)
        #expect(await waitUntil { await coordinator.state == .listening })
        #expect(await coordinator.voiceRequiresRetry == false)
    }

    @Test("rethrows voice startup failures, marks retry, and succeeds on retry")
    func voiceStartupFailureCanRetry() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .unknown
        )

        let start = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        await voice.failStart(with: TestVoiceError.startFailed)
        await #expect(throws: TestVoiceError.startFailed) {
            try await start.value
        }
        #expect(await coordinator.state == .greeting)
        #expect(await coordinator.voiceRequiresRetry)
        #expect(await voice.stopCallCount == 1)

        let retry = Task { try await coordinator.startVoiceSession() }
        #expect(await waitUntil { await voice.startCallCount == 2 })
        await voice.completeStart()
        #expect(try await retry.value == .speaking)
        #expect(await coordinator.voiceRequiresRetry == false)
        #expect(await voice.eventUpdatesCallCount == 2)
        await voice.emit(.userSpeechStarted)
        #expect(await waitUntil { await coordinator.state == .listening })
        #expect(await coordinator.voiceRequiresRetry == false)
    }

    @Test("cancelling voice startup stops the port, preserves greeting, and permits retry")
    func voiceStartupCancellationCanRetry() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .unknown
        )

        let canceled = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        canceled.cancel()
        await #expect(throws: CancellationError.self) {
            try await canceled.value
        }
        #expect(await waitUntil { await voice.stopCallCount == 1 })
        #expect(await coordinator.state == .greeting)
        #expect(await coordinator.voiceRequiresRetry == false)

        let retry = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        await voice.completeStart()
        #expect(try await retry.value == .speaking)
    }

    @Test("rejects duplicate voice startup without a second port call")
    func rejectsDuplicateVoiceStartup() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .unknown
        )

        let first = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        do {
            _ = try await coordinator.startVoiceSession()
            Issue.record("Expected duplicate voice startup to throw")
        } catch let error as AssistantSessionCoordinatorError {
            #expect(error == .voiceSessionStartInProgress)
        }
        #expect(await voice.startCallCount == 1)
        await voice.completeStart()
        #expect(try await first.value == .speaking)
    }

    @Test("rejects voice startup outside greeting with the reducer transition error")
    func rejectsVoiceStartupOutsideGreeting() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )

        do {
            _ = try await coordinator.startVoiceSession()
            Issue.record("Expected voice startup from idle to throw")
        } catch let error as AssistantStateTransitionError {
            #expect(error.sourceState == .idle)
            #expect(error.event == .voiceSessionReady)
        }
        #expect(await coordinator.state == .idle)
        #expect(await voice.startCallCount == 0)
    }

    @Test("consumes the canonical voice event sequence and clears retry state")
    func consumesCanonicalVoiceEvents() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .unknown
        )
        let start = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        await voice.completeStart()
        #expect(try await start.value == .speaking)

        await voice.emit(.userSpeechStarted)
        #expect(await waitUntil { await coordinator.state == .listening })
        await voice.emit(.userSpeechEnded)
        #expect(await waitUntil { await coordinator.state == .thinking })
        await voice.emit(.responseReady)
        #expect(await waitUntil { await coordinator.state == .speaking })
        #expect(await coordinator.voiceRequiresRetry == false)
    }

    @Test("forwards authorization-required voice events without changing session state")
    func forwardsAuthorizationRequiredWithoutChangingSessionState() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterSpeaking(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voice: voice,
            result: .unknown
        )

        var authorizationUpdates =
            (await coordinator.authorizationRequiredUpdates()).makeAsyncIterator()
        await voice.emit(.authorizationRequired)
        #expect(await authorizationUpdates.next() != nil)
        #expect(await coordinator.state == .speaking)
        #expect(await coordinator.voiceRequiresRetry == false)

        await voice.emit(.failure)
        #expect(await waitUntil { await coordinator.voiceRequiresRetry })
        #expect(await coordinator.state == .speaking)
    }

    @Test("maps assistant interruption to listening without a duplicate speech event")
    func assistantInterruptionEntersListening() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterSpeaking(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voice: voice,
            result: .unknown
        )

        await voice.emit(.assistantInterrupted)

        #expect(await waitUntil { await coordinator.state == .listening })
        #expect(await coordinator.voiceRequiresRetry == false)
    }

    @Test("protected end waits until active assistant output completes")
    func protectedEndWaitsForAssistantOutputCompletion() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterSpeaking(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voice: voice,
            result: .unknown
        )

        await voice.emit(.assistantOutputStarted)
        let ending = Task {
            try await coordinator.endSessionAfterCurrentVoiceTurnCompletes()
        }

        for _ in 0..<256 {
            await Task.yield()
        }
        #expect(await voice.stopCallCount == 0)
        #expect(await coordinator.state == .speaking)

        await voice.emit(.assistantOutputEnded)
        #expect(try await ending.value == .idle)
        #expect(await voice.stopCallCount == 1)
    }

    @Test("protected end remains blocked through listening and thinking")
    func protectedEndWaitsAcrossConversationStates() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterSpeaking(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voice: voice,
            result: .unknown
        )

        await voice.emit(.assistantOutputStarted)
        await voice.emit(.assistantInterrupted)
        #expect(await waitUntil { await coordinator.state == .listening })

        let ending = Task {
            try await coordinator.endSessionAfterCurrentVoiceTurnCompletes()
        }
        await voice.emit(.assistantOutputEnded)
        await voice.emit(.userSpeechEnded)
        #expect(await waitUntil { await coordinator.state == .thinking })
        for _ in 0..<256 { await Task.yield() }
        #expect(await voice.stopCallCount == 0)

        await voice.emit(.responseReady)
        await voice.emit(.assistantOutputStarted)
        #expect(await waitUntil { await coordinator.state == .speaking })
        for _ in 0..<256 { await Task.yield() }
        #expect(await voice.stopCallCount == 0)

        await voice.emit(.assistantOutputEnded)
        #expect(try await ending.value == .idle)
        #expect(await voice.stopCallCount == 1)
    }

    @Test("output lifecycle and unexpected provider events cannot reset speaking")
    func internalVoiceEventsPreserveSpeaking() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterSpeaking(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voice: voice,
            result: .unknown
        )

        await voice.emit(.assistantOutputStarted)
        await voice.emit(.assistantOutputEnded)
        for _ in 0..<64 { await Task.yield() }
        #expect(await coordinator.state == .speaking)
        #expect(await coordinator.voiceRequiresRetry == false)

        await voice.emit(.userSpeechEnded)
        #expect(await waitUntil { await coordinator.voiceRequiresRetry })
        #expect(await coordinator.state == .speaking)

        await voice.emit(.responseReady)
        for _ in 0..<64 { await Task.yield() }
        #expect(await coordinator.state == .speaking)
    }

    @Test("marks voice failure and illegal events retryable without changing state")
    func voiceFailureAndIllegalEventsPreserveStateAndPermitRetry() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .unknown
        )
        let start = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        await voice.completeStart()
        #expect(try await start.value == .speaking)

        await voice.emit(.failure)
        #expect(await waitUntil { await coordinator.voiceRequiresRetry })
        #expect(await coordinator.state == .speaking)

        await voice.emit(.responseReady)
        #expect(await waitUntil { await coordinator.voiceRequiresRetry })
        #expect(await coordinator.state == .speaking)

        await voice.emit(.userSpeechStarted)
        #expect(await waitUntil { await coordinator.state == .listening })
        #expect(await coordinator.voiceRequiresRetry == false)

        await voice.emit(.failure)
        #expect(await waitUntil { await coordinator.voiceRequiresRetry })
        #expect(await coordinator.state == .listening)
        await voice.emit(.userSpeechEnded)
        #expect(await waitUntil { await coordinator.state == .thinking })
        #expect(await coordinator.voiceRequiresRetry == false)
    }

    @Test("subscribes to voice events exactly once for a successful start")
    func subscribesToVoiceEventsOnce() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .unknown
        )
        let start = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        await voice.completeStart()
        #expect(try await start.value == .speaking)
        #expect(await voice.eventUpdatesCallCount == 1)

        await voice.emit(.userSpeechStarted)
        #expect(await waitUntil { await coordinator.state == .listening })
        #expect(await voice.eventUpdatesCallCount == 1)
    }

    @Test("known voice startup registers tools before start and sends the exact member result")
    func knownVoiceStartupRegistersAndRunsToolSession() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let toolPort = TestVoiceToolCallPort()
        let repository = RecordingToolRepository(summary: makeToolSummary(visits: 7))
        let memberID = try MemberID(rawValue: "M-known-tool")
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice,
            voiceToolCallConfiguration: VoiceToolCallSessionConfiguration(
                port: toolPort,
                weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                    repository: repository
                )
            )
        )
        let confidence = try RecognitionConfidence(value: 0.98)
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .known(memberID: memberID, confidence: confidence)
        )

        let start = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        #expect(await toolPort.toolCallUpdatesCallCount == 1)

        await voice.completeStart()
        #expect(try await start.value == .speaking)

        let call = VoiceToolCall(
            callID: "weekly-summary",
            kind: .getMemberWeeklySummary
        )
        await toolPort.emit(call)
        await toolPort.waitUntilSentCount(1)
        #expect(await repository.weeklySummaryRequests == [memberID])
        #expect(await toolPort.sentResults.first?.callID == call.callID)
        #expect(
            await toolPort.firstSentJSON
                == #"{"activity_met_minutes":120,"last_workout_at":null,"today_completed":true,"visits_this_week":7}"#
        )

        _ = try await coordinator.endSession()
    }

    @Test("unknown voice sessions do not register the tool stream")
    func unknownVoiceDoesNotRegisterTools() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let toolPort = TestVoiceToolCallPort()
        let repository = RecordingToolRepository(summary: makeToolSummary(visits: 1))
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice,
            voiceToolCallConfiguration: VoiceToolCallSessionConfiguration(
                port: toolPort,
                weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                    repository: repository
                )
            )
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .unknown
        )

        let start = Task {
            try await coordinator.startVoiceSession(direction: .postWorkoutReview)
        }
        await voice.waitForStartRequest()
        #expect(await toolPort.toolCallUpdatesCallCount == 0)
        await voice.completeStart()
        #expect(try await start.value == .speaking)
        _ = try await coordinator.endSession()
    }

    @Test("unknown voice registers enrollment tools and end clears unnamed samples")
    func unknownVoiceRunsEnrollmentToolSession() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let toolPort = TestVoiceToolCallPort()
        let enrollmentPort = TestVisitorEnrollmentPort()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice,
            visitorEnrollmentToolCallConfiguration:
                VisitorEnrollmentToolCallSessionConfiguration(
                    port: toolPort,
                    enrollmentPort: enrollmentPort
                )
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .unknown
        )

        let start = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        #expect(await toolPort.toolCallUpdatesCallCount == 1)
        await voice.completeStart()
        #expect(try await start.value == .speaking)

        await toolPort.emit(VoiceToolCall(
            callID: "consented-enrollment",
            kind: .beginVisitorEnrollment
        ))
        await toolPort.waitUntilSentCount(1)
        #expect(await enrollmentPort.beginCallCount == 1)
        #expect(await toolPort.sentResults.first?.payload == .enrollmentSamplesCaptured(3))

        _ = try await coordinator.endSession()
        #expect(await enrollmentPort.cancelCount == 1)
    }

    @Test("runner send failures set retry without changing the assistant state")
    func toolRunnerFailureSetsRetryWithoutChangingState() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let toolPort = TestVoiceToolCallPort(sendError: .sendFailed)
        let repository = RecordingToolRepository(summary: makeToolSummary(visits: 2))
        let memberID = try MemberID(rawValue: "M-tool-failure")
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice,
            voiceToolCallConfiguration: VoiceToolCallSessionConfiguration(
                port: toolPort,
                weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                    repository: repository
                )
            )
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .known(
                memberID: memberID,
                confidence: try RecognitionConfidence(value: 0.91)
            )
        )
        let start = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        await voice.completeStart()
        #expect(try await start.value == .speaking)

        await toolPort.emit(
            VoiceToolCall(callID: "send-failure", kind: .getMemberWeeklySummary)
        )
        await toolPort.waitUntilSendAttempt()
        #expect(await waitUntil { await coordinator.voiceRequiresRetry })
        #expect(await coordinator.state == .speaking)
        #expect(await voice.stopCallCount == 0)
        _ = try await coordinator.endSession()
    }

    @Test("ending cancels a suspended tool route before voice stop and sends nothing late")
    func endingCancelsToolRunnerBeforeVoiceStop() async throws {
        let log = TestCallLog()
        let hardware = TestHardware(log: log)
        let identity = TestIdentity()
        let voice = TestVoice(log: log)
        let toolPort = TestVoiceToolCallPort()
        let repository = CancellableToolRepository(log: log)
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice,
            voiceToolCallConfiguration: VoiceToolCallSessionConfiguration(
                port: toolPort,
                weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                    repository: repository
                )
            )
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .known(
                memberID: try MemberID(rawValue: "M-tool-end"),
                confidence: try RecognitionConfidence(value: 0.92)
            )
        )
        let start = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        await voice.completeStart()
        #expect(try await start.value == .speaking)
        await toolPort.emit(
            VoiceToolCall(callID: "suspended-route", kind: .getMemberWeeklySummary)
        )
        await repository.waitUntilRequested()

        await hardware.holdReturnHome()
        let end = Task { try await coordinator.endSession() }
        await repository.waitUntilCancelled()
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        #expect(await repository.wasCancelled)
        #expect(await log.entries == [.toolRouteCancelled, .voiceStop, .returnHome])

        await repository.succeed(with: makeToolSummary(visits: 9))
        await hardware.completeReturnHome()
        #expect(try await end.value == .idle)
        await Task.yield()
        #expect(await toolPort.sentResults.isEmpty)
        #expect(await coordinator.voiceRequiresRetry == false)
    }

    @Test("voice startup failure does not launch a registered tool runner")
    func voiceStartupFailureDoesNotLaunchToolRunner() async throws {
        let hardware = TestHardware()
        let identity = TestIdentity()
        let voice = TestVoice()
        let toolPort = TestVoiceToolCallPort()
        let repository = RecordingToolRepository(summary: makeToolSummary(visits: 3))
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice,
            voiceToolCallConfiguration: VoiceToolCallSessionConfiguration(
                port: toolPort,
                weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                    repository: repository
                )
            )
        )
        try await enterGreeting(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            result: .known(
                memberID: try MemberID(rawValue: "M-start-failure"),
                confidence: try RecognitionConfidence(value: 0.9)
            )
        )
        let start = Task { try await coordinator.startVoiceSession() }
        await voice.waitForStartRequest()
        #expect(await toolPort.toolCallUpdatesCallCount == 1)
        await voice.failStart(with: TestVoiceError.startFailed)
        await #expect(throws: TestVoiceError.startFailed) {
            try await start.value
        }

        await toolPort.emit(
            VoiceToolCall(callID: "no-runner", kind: .getMemberWeeklySummary)
        )
        await Task.yield()
        #expect(await repository.weeklySummaryRequests.isEmpty)
        #expect(await toolPort.sentResults.isEmpty)
        #expect(await coordinator.voiceRequiresRetry)
    }
}

private func enterRecognizing(
    coordinator: AssistantSessionCoordinator,
    hardware: TestHardware
) async throws {
    try await coordinator.confirmPresence(direction: .center)
    let operation = Task { try await coordinator.beginOrientation() }
    guard await waitUntil({ await hardware.hasPendingRotation }) else {
        Issue.record("Timed out waiting for orientation")
        return
    }
    await hardware.completeRotation()
    #expect(try await operation.value == .recognizing)
}

private func enterGreeting(
    coordinator: AssistantSessionCoordinator,
    hardware: TestHardware,
    identity: TestIdentity,
    result: RecognitionResult
) async throws {
    try await enterRecognizing(coordinator: coordinator, hardware: hardware)
    let operation = Task { try await coordinator.recognizeVisitor() }
    #expect(await waitUntil { await identity.hasPendingRequest })
    await identity.complete(with: result)
    #expect(try await operation.value == result)
    #expect(await coordinator.state == .greeting)
}

private func enterSpeaking(
    coordinator: AssistantSessionCoordinator,
    hardware: TestHardware,
    identity: TestIdentity,
    voice: TestVoice,
    result: RecognitionResult
) async throws {
    try await enterGreeting(
        coordinator: coordinator,
        hardware: hardware,
        identity: identity,
        result: result
    )
    let startup = Task { try await coordinator.startVoiceSession() }
    await voice.waitForStartRequest()
    await voice.completeStart()
    #expect(try await startup.value == .speaking)
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<4_096 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private enum HardwareFailure: Error, Equatable, Sendable {
    case immediate
}

private enum HomeFailure: Error, Equatable, Sendable {
    case injected
}

private enum TestCall: Equatable, Sendable {
    case voiceStop
    case hardwareStop
    case returnHome
    case toolRouteCancelled
}

private actor TestCallLog {
    private(set) var entries: [TestCall] = []

    func append(_ call: TestCall) {
        entries.append(call)
    }
}

private enum TestIdentityError: Error, Equatable, Sendable {
    case adapterFailure
}

private actor TestHardware: HardwareControlPort {
    private(set) var rotationTargets: [RotationAngle] = []
    private(set) var stopCallCount = 0
    private(set) var returnHomeCallCount = 0

    private var pendingRotation: CheckedContinuation<Void, any Error>?
    private var pendingReturnHome: CheckedContinuation<Void, any Error>?
    private var returnHomeIsPending = false
    private let log: TestCallLog?

    init(log: TestCallLog? = nil) {
        self.log = log
    }

    var hasPendingRotation: Bool {
        pendingRotation != nil
    }

    var hasPendingReturnHome: Bool {
        pendingReturnHome != nil
    }

    func holdReturnHome() {
        returnHomeIsPending = true
    }

    func rotate(to angle: RotationAngle) async throws {
        rotationTargets.append(angle)

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pendingRotation = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelPendingRotation() }
        })
    }

    func failPendingRotation(with error: HardwareFailure) {
        guard let pendingRotation else { return }
        self.pendingRotation = nil
        pendingRotation.resume(throwing: error)
    }

    func completeRotation() {
        guard let pendingRotation else { return }
        self.pendingRotation = nil
        pendingRotation.resume()
    }

    func completeReturnHome() {
        guard let pendingReturnHome else { return }
        self.pendingReturnHome = nil
        pendingReturnHome.resume()
    }

    func failPendingReturnHome(with error: any Error) {
        guard let pendingReturnHome else { return }
        self.pendingReturnHome = nil
        pendingReturnHome.resume(throwing: error)
    }

    func returnHome() async throws {
        returnHomeCallCount += 1
        await log?.append(.returnHome)
        guard returnHomeIsPending else { return }

        let requestID = UInt64(returnHomeCallCount)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingReturnHome = continuation
            }
        }, onCancel: {
            Task { await self.cancelPendingReturnHome(id: requestID) }
        })
    }

    func stop() async {
        stopCallCount += 1
        await log?.append(.hardwareStop)
        cancelPendingRotation()
        cancelPendingReturnHome()
    }

    private func cancelPendingRotation() {
        guard let pendingRotation else { return }
        self.pendingRotation = nil
        pendingRotation.resume(throwing: CancellationError())
    }

    private func cancelPendingReturnHome(id: UInt64) {
        guard id == UInt64(returnHomeCallCount) else { return }
        cancelPendingReturnHome()
    }

    private func cancelPendingReturnHome() {
        guard let pendingReturnHome else { return }
        self.pendingReturnHome = nil
        pendingReturnHome.resume(throwing: CancellationError())
    }
}

private actor TestIdentity: IdentityRecognitionPort {
    private(set) var callCount = 0
    private var pendingRequest: CheckedContinuation<RecognitionResult, any Error>?

    var hasPendingRequest: Bool {
        pendingRequest != nil
    }

    func recognizeCurrentVisitor() async throws -> RecognitionResult {
        callCount += 1

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<RecognitionResult, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                pendingRequest = continuation
            }
        }, onCancel: {
            Task { await self.cancelPendingRequest() }
        })
    }

    func complete(with result: RecognitionResult) {
        guard let pendingRequest else { return }
        self.pendingRequest = nil
        pendingRequest.resume(returning: result)
    }

    func fail(with error: any Error) {
        guard let pendingRequest else { return }
        self.pendingRequest = nil
        pendingRequest.resume(throwing: error)
    }

    private func cancelPendingRequest() {
        guard let pendingRequest else { return }
        self.pendingRequest = nil
        pendingRequest.resume(throwing: CancellationError())
    }
}

private enum TestVoiceError: Error, Equatable, Sendable {
    case startFailed
}

private actor TestVoice: VoiceSessionPort {
    private(set) var startContexts: [VoiceContext] = []
    private(set) var startDirections: [VoiceConversationDirection] = []
    private(set) var startMemberAddresses: [VoiceMemberAddress?] = []
    private(set) var startCallCount = 0
    private(set) var eventUpdatesCallCount = 0
    private(set) var stopCallCount = 0
    private let log: TestCallLog?

    private struct PendingStart {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var nextStartID: UInt64 = 0
    private var nextSubscriberID: UInt64 = 0
    private var pendingStart: PendingStart?
    private var startRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribers: [UInt64: AsyncStream<VoiceSessionEvent>.Continuation] = [:]
    private var retiredSubscribers: [AsyncStream<VoiceSessionEvent>.Continuation] = []
    private var active = false

    init(log: TestCallLog? = nil) {
        self.log = log
    }

    func start(context: VoiceContext) async throws {
        try await start(context: context, direction: .general)
    }

    func start(
        context: VoiceContext,
        direction: VoiceConversationDirection
    ) async throws {
        let requestID = nextStartID
        nextStartID &+= 1
        startCallCount += 1
        startContexts.append(context)
        startDirections.append(direction)

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                pendingStart = PendingStart(id: requestID, continuation: continuation)
                let waiters = startRequestWaiters
                startRequestWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }, onCancel: {
            Task { await self.cancelPendingStart(id: requestID) }
        })
    }

    func start(
        context: VoiceContext,
        direction: VoiceConversationDirection,
        memberAddress: VoiceMemberAddress?
    ) async throws {
        startMemberAddresses.append(memberAddress)
        try await start(context: context, direction: direction)
    }

    func eventUpdates() async -> AsyncStream<VoiceSessionEvent> {
        eventUpdatesCallCount += 1
        let subscriberID = nextSubscriberID
        nextSubscriberID &+= 1

        let pair = AsyncStream<VoiceSessionEvent>.makeStream(
            of: VoiceSessionEvent.self,
            bufferingPolicy: .unbounded
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(id: subscriberID) }
        }
        subscribers[subscriberID] = pair.continuation
        return pair.stream
    }

    func stop() async {
        stopCallCount += 1
        await log?.append(.voiceStop)
        active = false
        cancelCurrentStart()
        let activeSubscribers = Array(subscribers.values)
        retiredSubscribers.append(contentsOf: activeSubscribers)
        subscribers.removeAll()
        for continuation in activeSubscribers {
            continuation.finish()
        }
    }

    func completeStart() {
        guard let pendingStart else { return }
        self.pendingStart = nil
        active = true
        pendingStart.continuation.resume()
    }

    func waitForStartRequest() async {
        if pendingStart != nil { return }
        await withCheckedContinuation { continuation in
            if pendingStart != nil {
                continuation.resume()
            } else {
                startRequestWaiters.append(continuation)
            }
        }
    }

    func failStart(with error: any Error) {
        guard let pendingStart else { return }
        self.pendingStart = nil
        pendingStart.continuation.resume(throwing: error)
    }

    func emit(_ event: VoiceSessionEvent) {
        guard active else { return }
        for continuation in subscribers.values {
            _ = continuation.yield(event)
        }
    }

    func emitAfterStop(_ event: VoiceSessionEvent) {
        for continuation in retiredSubscribers {
            _ = continuation.yield(event)
        }
    }

    private func cancelPendingStart(id: UInt64) {
        guard let pendingStart, pendingStart.id == id else { return }
        self.pendingStart = nil
        pendingStart.continuation.resume(throwing: CancellationError())
    }

    private func cancelCurrentStart() {
        guard let pendingStart else { return }
        self.pendingStart = nil
        pendingStart.continuation.resume(throwing: CancellationError())
    }

    private func removeSubscriber(id: UInt64) {
        subscribers.removeValue(forKey: id)
    }
}

private actor ImmediateRecordingVoice: VoiceSessionPort {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start(context _: VoiceContext) async throws {
        startCallCount += 1
    }

    func eventUpdates() async -> AsyncStream<VoiceSessionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func stop() async {
        stopCallCount += 1
    }
}

private actor CancellableMemberAddressResolver {
    private var continuation: CheckedContinuation<Void, Never>?
    private var lookupWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancellationObserved = false

    func resolve(_: MemberID) async -> VoiceMemberAddress? {
        for waiter in lookupWaiters { waiter.resume() }
        lookupWaiters.removeAll()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation = $0 }
            return nil
        }, onCancel: {
            Task { await self.cancelPendingLookup() }
        })
    }

    func waitForLookup() async {
        if continuation != nil { return }
        await withCheckedContinuation { lookupWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    private func cancelPendingLookup() {
        cancellationObserved = true
        continuation?.resume()
        continuation = nil
    }
}

private func makeToolSummary(visits: Int) -> ExerciseSummary {
    ExerciseSummary(
        visitsThisWeek: visits,
        activityMETMinutes: 120,
        lastWorkoutAt: nil,
        todayCompleted: true
    )
}

private enum TestToolCallPortError: Error, Equatable, Sendable {
    case sendFailed
}

private actor TestVoiceToolCallPort: VoiceToolCallPort {
    private let stream: AsyncStream<VoiceToolCall>
    private let continuation: AsyncStream<VoiceToolCall>.Continuation
    private let sendError: TestToolCallPortError?
    private var sendAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var sentCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    private(set) var toolCallUpdatesCallCount = 0
    private(set) var sendCallCount = 0
    private(set) var sentResults: [VoiceToolResult] = []

    var firstSentJSON: String? {
        guard let result = sentResults.first else { return nil }
        return String(data: result.jsonData(), encoding: .utf8)
    }

    init(sendError: TestToolCallPortError? = nil) {
        let pair = AsyncStream<VoiceToolCall>.makeStream(
            of: VoiceToolCall.self,
            bufferingPolicy: .unbounded
        )
        stream = pair.stream
        continuation = pair.continuation
        self.sendError = sendError
    }

    func toolCallUpdates() async -> AsyncStream<VoiceToolCall> {
        toolCallUpdatesCallCount += 1
        return stream
    }

    func sendToolResult(_ result: VoiceToolResult) async throws {
        sendCallCount += 1
        let attemptWaiters = sendAttemptWaiters
        sendAttemptWaiters.removeAll()
        for waiter in attemptWaiters {
            waiter.resume()
        }
        try Task.checkCancellation()
        if let sendError {
            throw sendError
        }
        sentResults.append(result)
        let readyWaiters = sentCountWaiters
            .filter { $0.key <= sentResults.count }
            .flatMap(\.value)
        sentCountWaiters = sentCountWaiters.filter { $0.key > sentResults.count }
        for waiter in readyWaiters {
            waiter.resume()
        }
    }

    func emit(_ call: VoiceToolCall) {
        continuation.yield(call)
    }

    func finish() {
        continuation.finish()
    }

    func waitUntilSendAttempt() async {
        if sendCallCount > 0 { return }
        await withCheckedContinuation { continuation in
            sendAttemptWaiters.append(continuation)
        }
    }

    func waitUntilSentCount(_ count: Int) async {
        if sentResults.count >= count { return }
        await withCheckedContinuation { continuation in
            sentCountWaiters[count, default: []].append(continuation)
        }
    }

    deinit {
        continuation.finish()
    }
}

private actor TestVisitorEnrollmentPort: VisitorEnrollmentPort {
    private(set) var beginCallCount = 0
    private(set) var cancelCount = 0

    func begin(consentedAt _: Date) async throws -> VisitorEnrollmentBeginResult {
        beginCallCount += 1
        return .samplesCaptured(3)
    }

    func complete(
        memberID _: MemberID,
        address _: VoiceMemberAddress,
        completedAt _: Date
    ) async throws {}

    func cancel() async {
        cancelCount += 1
    }
}

private actor RecordingToolRepository: MemberRepository {
    private let summary: ExerciseSummary
    private(set) var weeklySummaryRequests: [MemberID] = []

    init(summary: ExerciseSummary) {
        self.summary = summary
    }

    func profile(for id: MemberID) async throws -> Member {
        throw ToolRepositoryError.profileUnsupported
    }

    func weeklySummary(for id: MemberID) async throws -> ExerciseSummary {
        weeklySummaryRequests.append(id)
        return summary
    }
}

private actor CancellableToolRepository: MemberRepository {
    private let log: TestCallLog
    private var pending: CheckedContinuation<ExerciseSummary, any Error>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var weeklySummaryRequests: [MemberID] = []
    private(set) var wasCancelled = false
    private var cancellationCompleted = false

    var hasPendingRequest: Bool {
        pending != nil
    }

    init(log: TestCallLog) {
        self.log = log
    }

    func profile(for id: MemberID) async throws -> Member {
        throw ToolRepositoryError.profileUnsupported
    }

    func weeklySummary(for id: MemberID) async throws -> ExerciseSummary {
        weeklySummaryRequests.append(id)
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ExerciseSummary, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending = continuation
            }
        }, onCancel: {
            Task { await self.cancelPending() }
        })
    }

    func waitUntilRequested() async {
        if weeklySummaryRequests.isEmpty {
            await withCheckedContinuation { continuation in
                requestWaiters.append(continuation)
            }
        }
    }

    func waitUntilCancelled() async {
        if cancellationCompleted { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func succeed(with summary: ExerciseSummary) {
        pending?.resume(returning: summary)
        pending = nil
    }

    private func cancelPending() async {
        guard let pending else { return }
        self.pending = nil
        wasCancelled = true
        await log.append(.toolRouteCancelled)
        pending.resume(throwing: CancellationError())
        cancellationCompleted = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private enum ToolRepositoryError: Error, Equatable, Sendable {
    case profileUnsupported
}
