import Foundation
import LumiDomain

/// Routes the two normalized enrollment tools for one Unknown voice session.
public actor VisitorEnrollmentToolCallRouter {
    public static let requiredSampleCount = 3

    private enum Phase {
        case idle
        case samplesCaptured
        case completed
    }

    private let port: any VisitorEnrollmentPort
    private let now: @Sendable () async -> Date
    private let memberIDGenerator: @Sendable () throws -> MemberID
    private var phase: Phase = .idle
    private var completedCalls: [String: CompletedEnrollmentCall] = [:]

    public init(
        port: any VisitorEnrollmentPort,
        now: @escaping @Sendable () async -> Date = { Date() },
        memberIDGenerator: @escaping @Sendable () throws -> MemberID = {
            try MemberID(rawValue: "local-\(UUID().uuidString.lowercased())")
        }
    ) {
        self.port = port
        self.now = now
        self.memberIDGenerator = memberIDGenerator
    }

    public func result(for call: VoiceToolCall) async throws -> VoiceToolResult {
        try Task.checkCancellation()

        if let completed = completedCalls[call.callID] {
            guard completed.kind == call.kind else {
                return VoiceToolResult(
                    callID: call.callID,
                    payload: .failure(.duplicateCall)
                )
            }
            return completed.result
        }

        let payload: VoiceToolResultPayload
        switch call.kind {
        case .beginVisitorEnrollment:
            payload = try await beginEnrollment()

        case let .completeVisitorEnrollment(address):
            payload = try await completeEnrollment(address: address)

        case .getMemberWeeklySummary, .unsupported:
            payload = .failure(.unsupportedTool)

        case .invalidArguments:
            payload = .failure(.invalidArguments)
        }

        let result = VoiceToolResult(callID: call.callID, payload: payload)
        completedCalls[call.callID] = CompletedEnrollmentCall(
            kind: call.kind,
            result: result
        )
        return result
    }

    public func cancelPendingEnrollment() async {
        guard phase == .samplesCaptured else { return }
        phase = .idle
        await port.cancel()
    }

    private func beginEnrollment() async throws -> VoiceToolResultPayload {
        guard phase == .idle else {
            return .failure(.enrollmentNotReady)
        }

        do {
            let consentedAt = await now()
            guard consentedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw VisitorEnrollmentRoutingError.failed
            }
            let outcome = try await port.begin(consentedAt: consentedAt)
            try Task.checkCancellation()

            guard case let .samplesCaptured(count) = outcome,
                  count == Self.requiredSampleCount
            else {
                await port.cancel()
                return .failure(.enrollmentUnavailable)
            }

            phase = .samplesCaptured
            return .enrollmentSamplesCaptured(count)
        } catch let cancellation as CancellationError {
            await port.cancel()
            throw cancellation
        } catch {
            await port.cancel()
            if Task.isCancelled {
                throw CancellationError()
            }
            return .failure(.enrollmentUnavailable)
        }
    }

    private func completeEnrollment(
        address: VoiceMemberAddress
    ) async throws -> VoiceToolResultPayload {
        guard phase == .samplesCaptured else {
            return .failure(.enrollmentNotReady)
        }

        do {
            let memberID = try memberIDGenerator()
            let completedAt = await now()
            guard completedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw VisitorEnrollmentRoutingError.failed
            }
            try await port.complete(
                memberID: memberID,
                address: address,
                completedAt: completedAt
            )
            // A successful atomic store commit wins a simultaneous task
            // cancellation. Reporting cancellation here would make a retry
            // appear safe even though the profile and embeddings now exist.
            phase = .completed
            return .enrollmentCompleted(address)
        } catch let cancellation as CancellationError {
            phase = .idle
            await port.cancel()
            throw cancellation
        } catch {
            phase = .idle
            await port.cancel()
            if Task.isCancelled {
                throw CancellationError()
            }
            return .failure(.enrollmentUnavailable)
        }
    }
}

private struct CompletedEnrollmentCall: Sendable {
    let kind: VoiceToolCallKind
    let result: VoiceToolResult
}

private enum VisitorEnrollmentRoutingError: Error {
    case failed
}
