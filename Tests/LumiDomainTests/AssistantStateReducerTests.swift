import Testing
import LumiDomain

@Test("rotating is parameterless and included in the twelve baseline states")
func rotatingIsIncludedInBaselineCases() {
    #expect(AssistantState.baselineCases.count == 12)
    #expect(AssistantState.baselineCases.contains(.rotating))
}

@Test("person confirmation preserves each direction from idle")
func personConfirmationPreservesDirection() throws {
    let reducer = AssistantStateReducer()

    for direction in PresenceDirection.allCases {
        let result = try reducer.reduce(
            .idle,
            event: .personConfirmed(direction: direction)
        )
        #expect(result == .detected(direction: direction))
    }
}

@Test("the approved orientation sequence is deterministic")
func approvedSequenceIsDeterministic() throws {
    let reducer = AssistantStateReducer()
    let events: [AssistantSessionEvent] = [
        .personConfirmed(direction: .right),
        .beginOrientation,
        .rotationCompleted,
    ]

    var first = AssistantState.idle
    for event in events {
        first = try reducer.reduce(first, event: event)
    }

    var second = AssistantState.idle
    for event in events {
        second = try reducer.reduce(second, event: event)
    }

    #expect(first == .recognizing)
    #expect(second == first)
}

@Test("identity resolution advances recognizing to greeting for known and unknown results")
func identityResolutionAdvancesToGreeting() throws {
    let reducer = AssistantStateReducer()
    let known = RecognitionResult.known(
        memberID: try MemberID(rawValue: "member-001"),
        confidence: try RecognitionConfidence(value: 0.9)
    )

    for result in [known, .unknown] {
        #expect(
            try reducer.reduce(
                .recognizing,
                event: .identityResolved(result)
            ) == .greeting
        )
    }
}

@Test("voice session readiness advances greeting to speaking")
func voiceSessionReadyAdvancesGreetingToSpeaking() throws {
    let reducer = AssistantStateReducer()

    #expect(
        try reducer.reduce(
            .greeting,
            event: .voiceSessionReady
        ) == .speaking
    )
}

@Test("user speech start advances speaking to listening")
func userSpeechStartedAdvancesSpeakingToListening() throws {
    let reducer = AssistantStateReducer()

    #expect(
        try reducer.reduce(
            .speaking,
            event: .userSpeechStarted
        ) == .listening
    )
}

@Test("user speech end advances listening to thinking")
func userSpeechEndedAdvancesListeningToThinking() throws {
    let reducer = AssistantStateReducer()

    #expect(
        try reducer.reduce(
            .listening,
            event: .userSpeechEnded
        ) == .thinking
    )
}

@Test("response readiness advances thinking to speaking")
func responseReadyAdvancesThinkingToSpeaking() throws {
    let reducer = AssistantStateReducer()

    #expect(
        try reducer.reduce(
            .thinking,
            event: .responseReady
        ) == .speaking
    )
}

@Test("session ended returns every active state to idle")
func sessionEndedReturnsEveryActiveStateToIdle() throws {
    let reducer = AssistantStateReducer()
    let activeStates: [AssistantState] = [
        .detected(direction: .left),
        .detected(direction: .center),
        .detected(direction: .right),
        .rotating,
        .recognizing,
        .greeting,
        .listening,
        .thinking,
        .speaking,
        .encouraging,
        .reminding,
        .confused,
    ]

    for state in activeStates {
        #expect(
            try reducer.reduce(state, event: .sessionEnded) == .idle,
            "Expected sessionEnded to return \(state) to idle"
        )
    }
}

@Test("session ended is rejected from idle and offline")
func sessionEndedRejectsIdleAndOffline() throws {
    let reducer = AssistantStateReducer()

    for state in [AssistantState.idle, .offline] {
        do {
            _ = try reducer.reduce(state, event: .sessionEnded)
            Issue.record("Expected sessionEnded from \(state) to throw")
        } catch {
            #expect(error.sourceState == state)
            #expect(error.event == .sessionEnded)
        }
    }
}

@Test("the canonical voice lifecycle is deterministic")
func canonicalVoiceLifecycleIsDeterministic() throws {
    let reducer = AssistantStateReducer()
    let events: [AssistantSessionEvent] = [
        .voiceSessionReady,
        .userSpeechStarted,
        .userSpeechEnded,
        .responseReady,
    ]

    var first = AssistantState.greeting
    for event in events {
        first = try reducer.reduce(first, event: event)
    }

    var second = AssistantState.greeting
    for event in events {
        second = try reducer.reduce(second, event: event)
    }

    #expect(first == .speaking)
    #expect(second == first)
}

@Test("orientation failure restores the original detected direction")
func orientationFailureRestoresDetectedDirection() throws {
    let reducer = AssistantStateReducer()

    for direction in PresenceDirection.allCases {
        let rotating = try reducer.reduce(
            .detected(direction: direction),
            event: .beginOrientation
        )
        let restored = try reducer.reduce(
            rotating,
            event: .orientationFailed(direction: direction)
        )

        #expect(restored == .detected(direction: direction))
    }
}

@Test("illegal transitions throw the typed error with source state and event")
func illegalTransitionsExposeSourceAndEvent() throws {
    let reducer = AssistantStateReducer()
    let known = RecognitionResult.known(
        memberID: try MemberID(rawValue: "member-001"),
        confidence: try RecognitionConfidence(value: 0.9)
    )
    let states: [AssistantState] = [
        .idle,
        .detected(direction: .left),
        .detected(direction: .center),
        .detected(direction: .right),
        .rotating,
        .recognizing,
        .greeting,
        .listening,
        .thinking,
        .speaking,
        .encouraging,
        .reminding,
        .confused,
        .offline,
    ]
    let events: [AssistantSessionEvent] = [
        .personConfirmed(direction: .center),
        .beginOrientation,
        .rotationCompleted,
        .orientationFailed(direction: .center),
        .identityResolved(.unknown),
        .identityResolved(known),
        .voiceSessionReady,
        .userSpeechStarted,
        .userSpeechEnded,
        .responseReady,
        .sessionEnded,
    ]

    for state in states {
        for event in events where !isLegal(state: state, event: event) {
            do {
                _ = try reducer.reduce(state, event: event)
                Issue.record("Expected illegal transition to throw: \(state), \(event)")
            } catch {
                #expect(error.sourceState == state)
                #expect(error.event == event)
            }
        }
    }
}

@Test("reducer and session events are Sendable values")
func reducerContractIsSendable() {
    acceptsSendable(AssistantStateReducer())
    acceptsSendable(AssistantSessionEvent.rotationCompleted)
    acceptsSendable(AssistantSessionEvent.identityResolved(.unknown))
    acceptsSendable(AssistantSessionEvent.voiceSessionReady)
    acceptsSendable(AssistantSessionEvent.userSpeechStarted)
    acceptsSendable(AssistantSessionEvent.userSpeechEnded)
    acceptsSendable(AssistantSessionEvent.responseReady)
    acceptsSendable(AssistantSessionEvent.sessionEnded)
}

private func isLegal(state: AssistantState, event: AssistantSessionEvent) -> Bool {
    switch (state, event) {
    case (.idle, .personConfirmed):
        true
    case (.detected, .beginOrientation):
        true
    case (.rotating, .rotationCompleted):
        true
    case (.rotating, .orientationFailed):
        true
    case (.recognizing, .identityResolved):
        true
    case (.greeting, .voiceSessionReady):
        true
    case (.speaking, .userSpeechStarted):
        true
    case (.listening, .userSpeechEnded):
        true
    case (.thinking, .responseReady):
        true
    case (.detected, .sessionEnded),
         (.rotating, .sessionEnded),
         (.recognizing, .sessionEnded),
         (.greeting, .sessionEnded),
         (.listening, .sessionEnded),
         (.thinking, .sessionEnded),
         (.speaking, .sessionEnded),
         (.encouraging, .sessionEnded),
         (.reminding, .sessionEnded),
         (.confused, .sessionEnded):
        true
    default:
        false
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
