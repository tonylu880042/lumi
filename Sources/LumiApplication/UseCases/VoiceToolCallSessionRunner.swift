import Foundation
import LumiDomain

/// Serially consumes one session's normalized voice tool calls.
public struct VoiceToolCallSessionRunner: Sendable {
    private let port: any VoiceToolCallPort
    private let toolCalls: AsyncStream<VoiceToolCall>
    private let router: VoiceToolCallRouter

    private init(
        port: any VoiceToolCallPort,
        toolCalls: AsyncStream<VoiceToolCall>,
        router: VoiceToolCallRouter
    ) {
        self.port = port
        self.toolCalls = toolCalls
        self.router = router
    }

    /// Registers the tool stream before returning a session runner.
    public static func prepare(
        port: any VoiceToolCallPort,
        memberID: MemberID,
        weeklySummaryUseCase: GetMemberWeeklySummaryUseCase
    ) async -> Self {
        let toolCalls = await port.toolCallUpdates()
        let router = VoiceToolCallRouter(
            memberID: memberID,
            weeklySummaryUseCase: weeklySummaryUseCase
        )
        return Self(
            port: port,
            toolCalls: toolCalls,
            router: router
        )
    }

    /// Runs until the registered stream finishes or one operation fails.
    public func run() async throws {
        try Task.checkCancellation()

        for await call in toolCalls {
            try Task.checkCancellation()
            let result = try await router.result(for: call)
            try Task.checkCancellation()
            try await port.sendToolResult(result)
        }

        try Task.checkCancellation()
    }
}
