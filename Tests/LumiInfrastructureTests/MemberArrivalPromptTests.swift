import Foundation
import LumiApplication
@testable import LumiInfrastructure
import Testing

@Suite("Member arrival and short revisit prompts")
struct MemberArrivalPromptTests {
    @Test("first daily arrival announces the weekly ordinal with matching encouragement",
          arguments: [1, 2, 3, 4, 7])
    func weeklyArrivalOpening(count: Int) throws {
        let context = VoiceMemberMemoryContext(
            highlight: .longAbsent, arrivalWeeklyMeetingDayCount: count,
            arrivalEncounterAt: Date(timeIntervalSince1970: 1_790_902_800)
        )
        for address in [nil, try VoiceMemberAddress(spokenLabel: "Angela")] {
            let prompt = makePrompt(address: address, context: context)
            let sentence = count == 1 ? "這週第一次見到你，很開心見到你"
                : count == 2 ? "這週第二次見到你，你很認真"
                : "這週已經見到你 \(count) 次"
            #expect(prompt.contains(sentence))
            #expect(prompt.contains("這次開場改為本週見面鼓勵"))
            #expect(prompt.contains("包含今天"))
            #expect(prompt.contains("不是正式完成運動紀錄"))
            #expect(prompt.contains("不要求會員回應"))
            #expect(!prompt.contains("溫柔問候近況"))
            #expect(!prompt.contains("1790902800"))
        }
    }

    @Test("short revisit says the brief phrase without repeating a weekly count")
    func shortRevisitOpening() throws {
        let context = VoiceMemberMemoryContext(highlight: .seenToday)
        for address in [nil, try VoiceMemberAddress(spokenLabel: "Angela")] {
            let prompt = makePrompt(address: address, context: context)
            #expect(prompt.contains("又見面啦，加油喔"))
            #expect(prompt.contains("不重報本週次數"))
            #expect(!prompt.contains("這次開場改為本週見面鼓勵"))
            #expect(!prompt.contains("這次開場改為離店鼓勵"))
        }
    }

    private func makePrompt(address: VoiceMemberAddress?, context: VoiceMemberMemoryContext) -> String {
        if let address {
            return OpenAIConversationPrompts.returningMember(
                address: address, memoryContext: context, includesWeeklySummaryTool: false
            )
        }
        return OpenAIConversationPrompts.anonymousReturningMemberPrompt(
            memoryContext: context, includesWeeklySummaryTool: false
        )
    }
}
