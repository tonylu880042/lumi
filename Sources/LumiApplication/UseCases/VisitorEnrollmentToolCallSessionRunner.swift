/// Serially consumes one Unknown visitor session's enrollment tool calls.
public struct VisitorEnrollmentToolCallSessionRunner: Sendable {
    private let port: any VoiceToolCallPort
    private let toolCalls: AsyncStream<VoiceToolCall>
    private let router: VisitorEnrollmentToolCallRouter

    private init(
        port: any VoiceToolCallPort,
        toolCalls: AsyncStream<VoiceToolCall>,
        router: VisitorEnrollmentToolCallRouter
    ) {
        self.port = port
        self.toolCalls = toolCalls
        self.router = router
    }

    /// Registers the provider stream before voice startup so no consented tool
    /// call can be lost between session readiness and runner launch.
    public static func prepare(
        port: any VoiceToolCallPort,
        enrollmentPort: any VisitorEnrollmentPort
    ) async -> Self {
        let toolCalls = await port.toolCallUpdates()
        return Self(
            port: port,
            toolCalls: toolCalls,
            router: VisitorEnrollmentToolCallRouter(port: enrollmentPort)
        )
    }

    /// Runs until the stream ends. Every terminal path discards any unnamed
    /// samples; a completed atomic enrollment makes that cleanup a no-op.
    public func run() async throws {
        do {
            try Task.checkCancellation()
            for await call in toolCalls {
                try Task.checkCancellation()
                let result = try await router.result(for: call)
                try Task.checkCancellation()
                try await port.sendToolResult(result)
            }
            await router.cancelPendingEnrollment()
            try Task.checkCancellation()
        } catch let cancellation as CancellationError {
            await router.cancelPendingEnrollment()
            throw cancellation
        } catch {
            await router.cancelPendingEnrollment()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
