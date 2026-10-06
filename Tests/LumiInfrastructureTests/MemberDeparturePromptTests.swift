import Foundation
import LumiApplication
@testable import LumiInfrastructure
import Testing

@Suite("Member departure prompts")
struct MemberDeparturePromptTests {
    @Test("departure opening gives the exact observed weekly count and appropriate encouragement", arguments: [1, 2, 3, 4, 7])
    func selectsDepartureOpening(count: Int) throws {
        let context = VoiceMemberMemoryContext(
            highlight: .seenToday, departureWeeklyMeetingDayCount: count,
            departureFirstMeetingAt: Date(timeIntervalSince1970: 1_790_902_800)
        )
        for address in [nil, try VoiceMemberAddress(spokenLabel: "Angela")] {
            let prompt: String
            if let address {
                prompt = OpenAIConversationPrompts.returningMember(
                    address: address, memoryContext: context, includesWeeklySummaryTool: false
                )
            } else {
                prompt = OpenAIConversationPrompts.anonymousReturningMemberPrompt(
                    memoryContext: context, includesWeeklySummaryTool: false
                )
            }
            #expect(prompt.contains("這週已經來 \(count) 次"))
            #expect(prompt.contains(count < 3 ? "再來湊滿三次" : "已達成每週三次"))
            #expect(prompt.contains("這次開場改為離店鼓勵"))
            #expect(!prompt.contains("又見面啦"))
            #expect(!prompt.contains("2026"))
            #expect(prompt.contains("不要求會員回應"))
        }
    }
}
