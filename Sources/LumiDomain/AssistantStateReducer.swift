/// Events accepted by the Phase 1 assistant-session state reducer.
public enum AssistantSessionEvent: Equatable, Sendable {
    case personConfirmed(direction: PresenceDirection)
    case beginOrientation
    case rotationCompleted
    case orientationFailed(direction: PresenceDirection)
    case identityResolved(RecognitionResult)
    case voiceSessionReady
    case userSpeechStarted
    case userSpeechEnded
    case responseReady
    case sessionEnded
}

/// A deterministic rejection for an event that is not legal in the source state.
public struct AssistantStateTransitionError: Error, Equatable, Sendable {
    /// The state supplied to the reducer before the rejected event.
    public let sourceState: AssistantState

    /// The event rejected by the reducer.
    public let event: AssistantSessionEvent

    init(sourceState: AssistantState, event: AssistantSessionEvent) {
        self.sourceState = sourceState
        self.event = event
    }
}

/// Pure, deterministic state transition function for the Phase 1 session flow.
public struct AssistantStateReducer: Sendable {
    public init() {}

    public func reduce(
        _ state: AssistantState,
        event: AssistantSessionEvent
    ) throws(AssistantStateTransitionError) -> AssistantState {
        switch (state, event) {
        case (.idle, let .personConfirmed(direction)):
            .detected(direction: direction)
        case (.detected, .beginOrientation):
            .rotating
        case (.rotating, .rotationCompleted):
            .recognizing
        case (.rotating, let .orientationFailed(direction)):
            .detected(direction: direction)
        case (.recognizing, .identityResolved):
            .greeting
        case (.greeting, .voiceSessionReady):
            .speaking
        case (.speaking, .userSpeechStarted):
            .listening
        case (.listening, .userSpeechEnded):
            .thinking
        case (.thinking, .responseReady):
            .speaking
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
            .idle
        default:
            throw AssistantStateTransitionError(sourceState: state, event: event)
        }
    }
}
