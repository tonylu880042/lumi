import Foundation
import LumiApplication
import LumiDomain
import Testing

@Suite("Visitor enrollment tool-call session runner")
struct VisitorEnrollmentToolCallSessionRunnerTests {
    @Test("prepare registers before run and stream end clears pending samples")
    func streamEndClearsPendingEnrollment() async throws {
        let toolPort = EnrollmentSessionToolPort()
        let enrollmentPort = EnrollmentSessionPort()
        let runner = await VisitorEnrollmentToolCallSessionRunner.prepare(
            port: toolPort,
            enrollmentPort: enrollmentPort
        )
        #expect(await toolPort.registrationCount == 1)

        let task = Task { try await runner.run() }
        await toolPort.emit(VoiceToolCall(
            callID: "begin",
            kind: .beginVisitorEnrollment
        ))
        await toolPort.waitForSentCount(1)
        await toolPort.finish()
        try await task.value

        #expect(await toolPort.sentResults.first?.payload == .enrollmentSamplesCaptured(3))
        #expect(await enrollmentPort.cancelCount == 1)
    }

    @Test("completed enrollment is committed once and needs no cleanup cancel")
    func completeEnrollmentFinishesCleanly() async throws {
        let toolPort = EnrollmentSessionToolPort()
        let enrollmentPort = EnrollmentSessionPort()
        let runner = await VisitorEnrollmentToolCallSessionRunner.prepare(
            port: toolPort,
            enrollmentPort: enrollmentPort
        )
        let address = try VoiceMemberAddress(spokenLabel: "Tony")
        let task = Task { try await runner.run() }

        await toolPort.emit(VoiceToolCall(
            callID: "begin",
            kind: .beginVisitorEnrollment
        ))
        await toolPort.waitForSentCount(1)
        await toolPort.emit(VoiceToolCall(
            callID: "complete",
            kind: .completeVisitorEnrollment(address)
        ))
        await toolPort.waitForSentCount(2)
        await toolPort.finish()
        try await task.value

        #expect(await enrollmentPort.completedAddresses == [address])
        #expect(await enrollmentPort.cancelCount == 0)
    }

    @Test("task cancellation clears pending enrollment and sends nothing late")
    func cancellationClearsPendingEnrollment() async throws {
        let toolPort = EnrollmentSessionToolPort()
        let enrollmentPort = EnrollmentSessionPort()
        let runner = await VisitorEnrollmentToolCallSessionRunner.prepare(
            port: toolPort,
            enrollmentPort: enrollmentPort
        )
        let task = Task { try await runner.run() }

        await toolPort.emit(VoiceToolCall(
            callID: "begin",
            kind: .beginVisitorEnrollment
        ))
        await toolPort.waitForSentCount(1)
        task.cancel()
        await toolPort.finish()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await enrollmentPort.cancelCount == 1)
    }
}

private actor EnrollmentSessionToolPort: VoiceToolCallPort {
    private let stream: AsyncStream<VoiceToolCall>
    private let continuation: AsyncStream<VoiceToolCall>.Continuation
    private var sentWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var registrationCount = 0
    private(set) var sentResults: [VoiceToolResult] = []

    init() {
        let pair = AsyncStream<VoiceToolCall>.makeStream(
            of: VoiceToolCall.self,
            bufferingPolicy: .unbounded
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func toolCallUpdates() async -> AsyncStream<VoiceToolCall> {
        registrationCount += 1
        return stream
    }

    func sendToolResult(_ result: VoiceToolResult) async throws {
        try Task.checkCancellation()
        sentResults.append(result)
        let waiters = sentWaiters
            .filter { $0.key <= sentResults.count }
            .flatMap(\.value)
        sentWaiters = sentWaiters.filter { $0.key > sentResults.count }
        for waiter in waiters { waiter.resume() }
    }

    func emit(_ call: VoiceToolCall) {
        continuation.yield(call)
    }

    func finish() {
        continuation.finish()
    }

    func waitForSentCount(_ count: Int) async {
        if sentResults.count >= count { return }
        await withCheckedContinuation { continuation in
            sentWaiters[count, default: []].append(continuation)
        }
    }
}

private actor EnrollmentSessionPort: VisitorEnrollmentPort {
    private(set) var completedAddresses: [VoiceMemberAddress] = []
    private(set) var cancelCount = 0

    func begin(consentedAt _: Date) async throws -> VisitorEnrollmentBeginResult {
        .samplesCaptured(3)
    }

    func complete(
        memberID _: MemberID,
        address: VoiceMemberAddress,
        completedAt _: Date
    ) async throws {
        completedAddresses.append(address)
    }

    func cancel() async {
        cancelCount += 1
    }
}
