import Foundation
import LumiDomain

/// The provider-neutral tool operation requested by a voice session.
public enum VoiceToolCallKind: Equatable, Sendable {
    /// Requests the existing weekly-summary Application use case for the
    /// member bound to the current voice session.
    case getMemberWeeklySummary

    /// Records one of the bounded exercise states explicitly volunteered by
    /// the currently bound member. The MemberID and timestamp are owned by
    /// the Application session and never arrive from the provider.
    case recordExerciseDisclosure(MemberExerciseDisclosure)

    /// Corrects or retracts the current member's previously disclosed
    /// completion. The call has no provider-supplied member ID or timestamp.
    case correctMemberExerciseDisclosure

    /// Starts the current Unknown visitor's explicitly consented enrollment.
    case beginVisitorEnrollment

    /// Commits the current pending enrollment using only a validated spoken
    /// address. The generated local member ID never crosses this tool value.
    case completeVisitorEnrollment(VoiceMemberAddress)

    /// Requests a contextual, one-time close of the current conversation.
    /// This carries no transcript, member identity, or provider arguments.
    case endConversation

    /// Represents a provider tool name that Lumi does not support.
    case unsupported

    /// Represents arguments that could not be mapped to a supported tool.
    case invalidArguments
}

/// A normalized tool call with an opaque provider correlation value.
public struct VoiceToolCall: Equatable, Sendable {
    public let callID: String
    public let kind: VoiceToolCallKind

    public init(callID: String, kind: VoiceToolCallKind) {
        self.callID = callID
        self.kind = kind
    }
}

/// Stable failure codes for provider-neutral voice tool results.
public enum VoiceToolFailureCode: String, Equatable, Sendable {
    case unsupportedTool = "unsupported_tool"
    case invalidArguments = "invalid_arguments"
    case duplicateCall = "duplicate_call"
    case memberDataUnavailable = "member_data_unavailable"
    case invalidData = "invalid_data"
    case enrollmentUnavailable = "enrollment_unavailable"
    case enrollmentNotReady = "enrollment_not_ready"
    case memberMemoryUnavailable = "member_memory_unavailable"
}

/// The provider-neutral result payload for one voice tool call.
public enum VoiceToolResultPayload: Equatable, Sendable {
    case success(MemberWeeklySummaryToolResult)
    case exerciseDisclosureRecorded(MemberExerciseDisclosure)
    case exerciseDisclosureCorrected
    case exerciseDisclosureCorrectionNotFound
    case enrollmentSamplesCaptured(Int)
    case enrollmentCompleted(VoiceMemberAddress)
    case failure(VoiceToolFailureCode)
}

/// A result correlated to one opaque voice tool call ID.
public struct VoiceToolResult: Equatable, Sendable {
    public let callID: String
    public let payload: VoiceToolResultPayload

    public init(callID: String, payload: VoiceToolResultPayload) {
        self.callID = callID
        self.payload = payload
    }

    /// Returns deterministic provider-neutral JSON without transport metadata.
    ///
    /// The call ID is kept only for transport correlation and is intentionally
    /// excluded from the result payload.
    public func jsonData() -> Data {
        switch payload {
        case let .success(summary):
            return summary.jsonData()
        case let .exerciseDisclosureRecorded(disclosure):
            let disclosureValue: String
            switch disclosure {
            case .preparing:
                disclosureValue = "preparing"
            case .justCompleted:
                disclosureValue = "just_completed"
            case .completedToday:
                disclosureValue = "completed_today"
            }
            let persistence: String
            switch disclosure.persistenceScope {
            case .session:
                persistence = "session"
            case .day:
                persistence = "day"
            }
            let status = disclosure.isPersistent ? "recorded" : "session_only"
            return Data(
                "{\"exercise_state\":\"\(disclosureValue)\",\"persistence\":\"\(persistence)\",\"status\":\"\(status)\"}"
                    .utf8
            )
        case .exerciseDisclosureCorrected:
            return Data("{\"status\":\"exercise_disclosure_corrected\"}".utf8)
        case .exerciseDisclosureCorrectionNotFound:
            return Data("{\"status\":\"no_current_exercise_disclosure\"}".utf8)
        case let .enrollmentSamplesCaptured(count):
            return Data(
                "{\"captured_sample_count\":\(count),\"status\":\"samples_captured\"}"
                    .utf8
            )
        case let .enrollmentCompleted(address):
            return Data(
                "{\"spoken_label\":\"\(address.spokenLabel)\",\"status\":\"enrollment_complete\"}"
                    .utf8
            )
        case let .failure(code):
            return Data("{\"error\":\"\(code.rawValue)\"}".utf8)
        }
    }
}

/// Companion Application boundary for provider-neutral voice tool transport.
///
/// Implementations normalize provider calls before yielding them and preserve
/// native task cancellation while sending results. Provider wire formats and
/// business routing remain outside this contract.
public protocol VoiceToolCallPort: Sendable {
    /// Yields normalized calls in the order received by the voice session.
    func toolCallUpdates() async -> AsyncStream<VoiceToolCall>

    /// Sends one normalized result while preserving transport errors and
    /// `CancellationError`.
    func sendToolResult(_ result: VoiceToolResult) async throws
}
