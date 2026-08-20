import Foundation
import LumiApplication
import LumiDomain
import Testing

@Suite("Voice tool-call port contract")
struct VoiceToolCallPortContractTests {
    @Test("known tool calls preserve opaque call IDs without carrying a MemberID")
    func knownToolCallPreservesOpaqueValues() throws {
        let call = VoiceToolCall(
            callID: "opaque-call-id",
            kind: .getMemberWeeklySummary
        )

        #expect(call.callID == "opaque-call-id")
        #expect(call.kind == .getMemberWeeklySummary)
        #expect(call == call)
        acceptsSendable(call)
        acceptsSendable(call.kind)
    }

    @Test("known tool calls carry no member ID or raw provider arguments")
    func knownToolCallHasNoMemberIDOrRawArguments() {
        let call = VoiceToolCall(
            callID: "opaque-call-id",
            kind: .getMemberWeeklySummary
        )
        let kindMirror = Mirror(reflecting: call.kind)

        #expect(kindMirror.children.isEmpty)
        #expect(!String(describing: call.kind).contains("member-secret-marker"))
        #expect(!String(describing: call.kind).contains("raw-provider-arguments"))
    }

    @Test("unsupported and invalid argument calls remain provider-neutral values")
    func unsupportedAndInvalidCallsAreProviderNeutral() {
        let unsupported = VoiceToolCall(callID: "unknown-call", kind: .unsupported)
        let invalid = VoiceToolCall(callID: "invalid-call", kind: .invalidArguments)

        #expect(unsupported.kind == .unsupported)
        #expect(invalid.kind == .invalidArguments)
        #expect(unsupported.callID == "unknown-call")
        #expect(invalid.callID == "invalid-call")
        acceptsSendable(unsupported)
        acceptsSendable(invalid)
    }

    @Test("successful result reuses the exact weekly summary JSON")
    func successfulResultUsesExistingSummaryJSON() async throws {
        let memberID = try MemberID(rawValue: "M-002")
        let repository = SummaryRepository(
            summary: ExerciseSummary(
                visitsThisWeek: 2,
                activityMETMinutes: 580.5,
                lastWorkoutAt: Date(timeIntervalSince1970: 1_785_983_400),
                todayCompleted: false
            )
        )
        let summary = try await GetMemberWeeklySummaryUseCase(
            repository: repository
        ).execute(for: memberID)
        let result = VoiceToolResult(
            callID: "opaque-call-id",
            payload: .success(summary)
        )

        #expect(
            String(data: result.jsonData(), encoding: .utf8)
                == #"{"activity_met_minutes":580.5,"last_workout_at":"2026-08-06T02:30:00.000Z","today_completed":false,"visits_this_week":2}"#
        )
        acceptsSendable(result)
        acceptsSendable(result.payload)
    }

    @Test("every failure code has exact deterministic redacted JSON")
    func failureCodesHaveExactRedactedJSON() {
        let cases: [(VoiceToolFailureCode, String)] = [
            (.unsupportedTool, "unsupported_tool"),
            (.invalidArguments, "invalid_arguments"),
            (.duplicateCall, "duplicate_call"),
            (.memberDataUnavailable, "member_data_unavailable"),
            (.invalidData, "invalid_data")
        ]

        for (code, rawValue) in cases {
            let result = VoiceToolResult(
                callID: "opaque-call-id",
                payload: .failure(code)
            )
            let json = String(data: result.jsonData(), encoding: .utf8)

            #expect(code.rawValue == rawValue)
            #expect(json == "{\"error\":\"\(rawValue)\"}")
            guard let json else {
                Issue.record("Tool failure JSON must be valid UTF-8")
                continue
            }
            #expect(!json.contains("opaque-call-id"))
            #expect(!json.contains("member-secret-marker"))
            #expect(!json.contains("raw-tool-name"))
            acceptsSendable(code)
            acceptsSendable(result)
        }
    }

    @Test("companion port exposes tool updates and result sending")
    func companionPortHasProviderNeutralShape() async throws {
        let port = ContractVoiceToolCallPort()
        let existentialPort: any VoiceToolCallPort = port
        acceptsSendable(existentialPort)

        _ = await existentialPort.toolCallUpdates()

        let result = VoiceToolResult(
            callID: "opaque-call-id",
            payload: .failure(.invalidArguments)
        )
        try await existentialPort.sendToolResult(result)

        #expect(await port.sentResults == [result])
    }
}

private actor ContractVoiceToolCallPort: VoiceToolCallPort {
    private let stream: AsyncStream<VoiceToolCall>
    private let continuation: AsyncStream<VoiceToolCall>.Continuation
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
        stream
    }

    func sendToolResult(_ result: VoiceToolResult) async throws {
        sentResults.append(result)
    }

    deinit {
        continuation.finish()
    }
}

private actor SummaryRepository: MemberRepository {
    private let summary: ExerciseSummary

    init(summary: ExerciseSummary) {
        self.summary = summary
    }

    func profile(for id: MemberID) async throws -> Member {
        throw SummaryRepositoryError.unsupported
    }

    func weeklySummary(for id: MemberID) async throws -> ExerciseSummary {
        summary
    }
}

private enum SummaryRepositoryError: Error, Sendable {
    case unsupported
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
