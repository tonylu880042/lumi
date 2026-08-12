import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The smallest injectable HTTP boundary needed by SDP signaling.
///
/// Implementations return the response bytes and metadata without interpreting
/// provider payloads. Tests inject an in-memory actor; production uses the
/// URLSession-backed implementation below.
protocol OpenAIRealtimeSDPDataLoader: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Provider-specific signaling seam consumed by an Infrastructure transport.
protocol OpenAIRealtimeSDPSignaling: Sendable {
    func exchange(
        offerSDP: String,
        clientSecret: OpenAIRealtimeClientSecret
    ) async throws -> String
}

/// Errors produced while exchanging an SDP offer for a remote SDP answer.
///
/// These cases intentionally contain no request, credential, response-body, or
/// underlying SDK details. A status code is safe to retain for retry and
/// diagnostics while all other provider data stays at this boundary.
enum OpenAIRealtimeSDPSignalingError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case nonHTTPResponse
    case httpStatus(statusCode: Int)
    case emptyAnswer
    case invalidUTF8Answer
    case transportFailure

    var description: String {
        switch self {
        case .nonHTTPResponse:
            return "SDP signaling returned a non-HTTP response."
        case .httpStatus(let statusCode):
            return "SDP signaling rejected the request (HTTP \(statusCode))."
        case .emptyAnswer:
            return "SDP signaling returned an empty answer."
        case .invalidUTF8Answer:
            return "SDP signaling returned an invalid UTF-8 answer."
        case .transportFailure:
            return "SDP signaling transport failed."
        }
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: ["reason": description], displayStyle: .enum)
    }
}

/// Foundation implementation of the injected data-loader boundary.
struct OpenAIRealtimeURLSessionDataLoader:
    OpenAIRealtimeSDPDataLoader,
    Sendable
{
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Loads one request and cancels its underlying URLSession task when the
    /// caller task is cancelled.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Executes OpenAI's ephemeral-token WebRTC SDP exchange.
struct OpenAIRealtimeSDPSignalingClient:
    OpenAIRealtimeSDPSignaling,
    Sendable
{
    static let endpointURL = URL(string: "https://api.openai.com/v1/realtime/calls")!

    private let dataLoader: any OpenAIRealtimeSDPDataLoader

    /// Creates a signaling client around an injected request loader.
    init(dataLoader: any OpenAIRealtimeSDPDataLoader) {
        self.dataLoader = dataLoader
    }

    /// Creates a production client backed by URLSession.
    init(session: URLSession = .shared) {
        self.dataLoader = OpenAIRealtimeURLSessionDataLoader(session: session)
    }

    /// Exchanges an offer SDP for the provider's remote answer SDP.
    func exchange(
        offerSDP: String,
        clientSecret: OpenAIRealtimeClientSecret
    ) async throws -> String {
        var request = URLRequest(url: Self.endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(clientSecret.value)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = Data(offerSDP.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataLoader.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw OpenAIRealtimeSDPSignalingError.transportFailure
        }

        guard !Task.isCancelled else {
            throw CancellationError()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIRealtimeSDPSignalingError.nonHTTPResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw OpenAIRealtimeSDPSignalingError.httpStatus(
                statusCode: httpResponse.statusCode
            )
        }

        guard let answer = String(data: data, encoding: .utf8) else {
            throw OpenAIRealtimeSDPSignalingError.invalidUTF8Answer
        }

        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIRealtimeSDPSignalingError.emptyAnswer
        }

        return answer
    }
}
