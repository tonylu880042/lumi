import Foundation
import LumiApplication
import LumiDomain
import Testing

@Suite("Visitor enrollment tool-call router")
struct VisitorEnrollmentToolCallRouterTests {
    private let consentedAt = Date(timeIntervalSince1970: 1_787_390_400)
    private let completedAt = Date(timeIntervalSince1970: 1_787_390_430)

    @Test("begin captures exactly three pending samples after consent")
    func beginCapturesThreePendingSamples() async throws {
        let port = RecordingVisitorEnrollmentPort(beginResult: .samplesCaptured(3))
        let router = makeRouter(port: port)

        let result = try await router.result(for: VoiceToolCall(
            callID: "begin-call",
            kind: .beginVisitorEnrollment
        ))

        #expect(result.payload == .enrollmentSamplesCaptured(3))
        #expect(
            String(data: result.jsonData(), encoding: .utf8)
                == #"{"captured_sample_count":3,"status":"samples_captured"}"#
        )
        #expect(await port.beginDates == [consentedAt])
        #expect(await port.completedMemberIDs.isEmpty)
    }

    @Test("complete before begin fails closed without writing")
    func completeBeforeBeginFailsClosed() async throws {
        let port = RecordingVisitorEnrollmentPort(beginResult: .samplesCaptured(3))
        let router = makeRouter(port: port)
        let address = try VoiceMemberAddress(spokenLabel: "Tony")

        let result = try await router.result(for: VoiceToolCall(
            callID: "early-complete",
            kind: .completeVisitorEnrollment(address)
        ))

        #expect(result.payload == .failure(.enrollmentNotReady))
        #expect(await port.beginDates.isEmpty)
        #expect(await port.completedMemberIDs.isEmpty)
    }

    @Test("complete binds generated local ID and returns only the spoken label")
    func completeBindsGeneratedIDWithoutExposingIt() async throws {
        let memberID = try MemberID(rawValue: "local-fixed-uuid")
        let port = RecordingVisitorEnrollmentPort(beginResult: .samplesCaptured(3))
        let router = makeRouter(port: port, memberID: memberID)
        let address = try VoiceMemberAddress(spokenLabel: "Tony")

        _ = try await router.result(for: VoiceToolCall(
            callID: "begin-call",
            kind: .beginVisitorEnrollment
        ))
        let result = try await router.result(for: VoiceToolCall(
            callID: "complete-call",
            kind: .completeVisitorEnrollment(address)
        ))

        #expect(result.payload == .enrollmentCompleted(address))
        let json = String(data: result.jsonData(), encoding: .utf8)
        #expect(json == #"{"spoken_label":"Tony","status":"enrollment_complete"}"#)
        #expect(!json.orEmpty.contains(memberID.rawValue))
        #expect(await port.completedMemberIDs == [memberID])
        #expect(await port.completedAddresses == [address])
        #expect(await port.completedDates == [completedAt])
    }

    @Test("no usable face cancels pending state and returns a fixed failure")
    func noUsableFaceCancelsPendingState() async throws {
        let port = RecordingVisitorEnrollmentPort(beginResult: .noUsableFace)
        let router = makeRouter(port: port)

        let result = try await router.result(for: VoiceToolCall(
            callID: "no-face",
            kind: .beginVisitorEnrollment
        ))

        #expect(result.payload == .failure(.enrollmentUnavailable))
        #expect(await port.cancelCount == 1)
    }

    @Test("wrong captured count fails closed and clears pending samples")
    func wrongCapturedCountFailsClosed() async throws {
        let port = RecordingVisitorEnrollmentPort(beginResult: .samplesCaptured(2))
        let router = makeRouter(port: port)

        let result = try await router.result(for: VoiceToolCall(
            callID: "short-capture",
            kind: .beginVisitorEnrollment
        ))

        #expect(result.payload == .failure(.enrollmentUnavailable))
        #expect(await port.cancelCount == 1)
    }

    @Test("completed calls replay without recapturing or rewriting")
    func completedCallsAreIdempotent() async throws {
        let port = RecordingVisitorEnrollmentPort(beginResult: .samplesCaptured(3))
        let router = makeRouter(port: port)
        let begin = VoiceToolCall(callID: "same-begin", kind: .beginVisitorEnrollment)

        let first = try await router.result(for: begin)
        let replay = try await router.result(for: begin)

        #expect(replay == first)
        #expect(await port.beginDates == [consentedAt])
    }

    @Test("a different begin call cannot overwrite a pending enrollment")
    func secondBeginCannotOverwritePendingEnrollment() async throws {
        let port = RecordingVisitorEnrollmentPort(beginResult: .samplesCaptured(3))
        let router = makeRouter(port: port)

        _ = try await router.result(for: VoiceToolCall(
            callID: "first-begin",
            kind: .beginVisitorEnrollment
        ))
        let second = try await router.result(for: VoiceToolCall(
            callID: "second-begin",
            kind: .beginVisitorEnrollment
        ))

        #expect(second.payload == .failure(.enrollmentNotReady))
        #expect(await port.beginDates == [consentedAt])
    }

    @Test("session cancellation clears pending samples")
    func sessionCancellationClearsPendingSamples() async throws {
        let port = RecordingVisitorEnrollmentPort(beginResult: .samplesCaptured(3))
        let router = makeRouter(port: port)

        _ = try await router.result(for: VoiceToolCall(
            callID: "begin-before-cancel",
            kind: .beginVisitorEnrollment
        ))
        await router.cancelPendingEnrollment()

        #expect(await port.cancelCount == 1)
        let address = try VoiceMemberAddress(spokenLabel: "Tony")
        let result = try await router.result(for: VoiceToolCall(
            callID: "complete-after-cancel",
            kind: .completeVisitorEnrollment(address)
        ))
        #expect(result.payload == .failure(.enrollmentNotReady))
    }

    @Test("a completed atomic commit wins a simultaneous task cancellation")
    func committedCompletionWinsCancellation() async throws {
        let port = CommitWinningVisitorEnrollmentPort()
        let address = try VoiceMemberAddress(spokenLabel: "Tony")
        let router = VisitorEnrollmentToolCallRouter(
            port: port,
            now: { Date(timeIntervalSince1970: 1_787_390_400) },
            memberIDGenerator: { try MemberID(rawValue: "local-commit-wins") }
        )
        _ = try await router.result(for: VoiceToolCall(
            callID: "begin",
            kind: .beginVisitorEnrollment
        ))

        let task = Task {
            try await router.result(for: VoiceToolCall(
                callID: "complete",
                kind: .completeVisitorEnrollment(address)
            ))
        }
        await port.waitUntilCommitStarted()
        task.cancel()
        await port.finishCommittedWrite()

        #expect(try await task.value.payload == .enrollmentCompleted(address))
        #expect(await port.cancelCount == 0)
    }

    @Test("contract values and router remain Sendable")
    func valuesRemainSendable() throws {
        acceptsSendable(VisitorEnrollmentBeginResult.samplesCaptured(3))
        acceptsSendable(try VoiceMemberAddress(spokenLabel: "Tony"))
        acceptsSendable(RecordingVisitorEnrollmentPort(beginResult: .noUsableFace))
        acceptsSendable(makeRouter(
            port: RecordingVisitorEnrollmentPort(beginResult: .noUsableFace)
        ))
    }

    private func makeRouter(
        port: RecordingVisitorEnrollmentPort,
        memberID: MemberID? = nil
    ) -> VisitorEnrollmentToolCallRouter {
        let generatedID = memberID ?? {
            do {
                return try MemberID(rawValue: "local-default-uuid")
            } catch {
                preconditionFailure("Test member ID must remain valid")
            }
        }()
        return VisitorEnrollmentToolCallRouter(
            port: port,
            now: {
                await port.nextDate(
                    consentedAt: consentedAt,
                    completedAt: completedAt
                )
            },
            memberIDGenerator: { generatedID }
        )
    }
}

private actor RecordingVisitorEnrollmentPort: VisitorEnrollmentPort {
    private let beginResult: VisitorEnrollmentBeginResult
    private var dateRequestCount = 0
    private(set) var beginDates: [Date] = []
    private(set) var completedMemberIDs: [MemberID] = []
    private(set) var completedAddresses: [VoiceMemberAddress] = []
    private(set) var completedDates: [Date] = []
    private(set) var cancelCount = 0

    init(beginResult: VisitorEnrollmentBeginResult) {
        self.beginResult = beginResult
    }

    func nextDate(consentedAt: Date, completedAt: Date) -> Date {
        defer { dateRequestCount += 1 }
        return dateRequestCount == 0 ? consentedAt : completedAt
    }

    func begin(consentedAt: Date) async throws -> VisitorEnrollmentBeginResult {
        beginDates.append(consentedAt)
        return beginResult
    }

    func complete(
        memberID: MemberID,
        address: VoiceMemberAddress,
        completedAt: Date
    ) async throws {
        completedMemberIDs.append(memberID)
        completedAddresses.append(address)
        completedDates.append(completedAt)
    }

    func cancel() async {
        cancelCount += 1
    }
}

private actor CommitWinningVisitorEnrollmentPort: VisitorEnrollmentPort {
    private var commitContinuation: CheckedContinuation<Void, Never>?
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelCount = 0

    func begin(consentedAt _: Date) async throws -> VisitorEnrollmentBeginResult {
        .samplesCaptured(3)
    }

    func complete(
        memberID _: MemberID,
        address _: VoiceMemberAddress,
        completedAt _: Date
    ) async throws {
        let waiters = commitWaiters
        commitWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            commitContinuation = continuation
        }
    }

    func cancel() async {
        cancelCount += 1
    }

    func waitUntilCommitStarted() async {
        if commitContinuation != nil { return }
        await withCheckedContinuation { continuation in
            commitWaiters.append(continuation)
        }
    }

    func finishCommittedWrite() {
        commitContinuation?.resume()
        commitContinuation = nil
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
