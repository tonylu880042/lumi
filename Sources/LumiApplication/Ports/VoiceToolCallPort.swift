import Foundation
import LumiDomain

/// The provider-neutral tool operation requested by a voice session.
public enum VoiceToolCallKind: Equatable, Sendable {
    /// Requests the existing weekly-summary Application use case.
    case getMemberWeeklySummary(memberID: MemberID)

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
}

/// The provider-neutral result payload for one voice tool call.
public enum VoiceToolResultPayload: Equatable, Sendable {
    case success(MemberWeeklySummaryToolResult)
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
