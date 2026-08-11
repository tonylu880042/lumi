import LumiDomain

/// Presentation-owned trigger for a short-lived Avatar event.
///
/// This deliberately mirrors `AssistantEvent` one-to-one while keeping Domain
/// event types out of the UI-facing contract.
public enum AvatarEventCommand: Equatable, Sendable {
    case playful
    case memberRecognized
    case firstVisit
    case longTimeNoSee
    case goalAchieved
    case weeklyGoalCompleted
    case error
}

/// Exhaustive Domain-to-Presentation event mapper.
public struct AvatarEventCommandMapper: Sendable {
    public init() {}

    public func map(_ event: AssistantEvent) -> AvatarEventCommand {
        switch event {
        case .playful: .playful
        case .memberRecognized: .memberRecognized
        case .firstVisit: .firstVisit
        case .longTimeNoSee: .longTimeNoSee
        case .goalAchieved: .goalAchieved
        case .weeklyGoalCompleted: .weeklyGoalCompleted
        case .error: .error
        }
    }
}
