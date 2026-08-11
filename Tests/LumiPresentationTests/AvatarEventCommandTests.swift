import Testing
import LumiDomain
@testable import LumiPresentation

@Test("每個 Domain AssistantEvent 都有對應的 Presentation AvatarEventCommand",
      arguments: AssistantEvent.allCases)
func mapsEveryAssistantEventToAvatarEventCommand(event: AssistantEvent) {
    let command = AvatarEventCommandMapper().map(event)

    switch (event, command) {
    case (.playful, .playful),
         (.memberRecognized, .memberRecognized),
         (.firstVisit, .firstVisit),
         (.longTimeNoSee, .longTimeNoSee),
         (.goalAchieved, .goalAchieved),
         (.weeklyGoalCompleted, .weeklyGoalCompleted),
         (.error, .error):
        break
    default:
        Issue.record("Domain event \(event) mapped to unexpected command \(command)")
    }
}

@Test("AvatarEventCommand 是可比較且可跨 concurrency 邊界傳遞的 Presentation 契約")
func avatarEventCommandIsEquatableAndSendable() {
    let first = AvatarEventCommand.memberRecognized
    let second = AvatarEventCommand.memberRecognized

    #expect(first == second)
    requireSendable(first)
}

private func requireSendable<T: Sendable>(_ value: T) {
    _ = value
}
