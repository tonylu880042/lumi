import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LumiApplication

/// Fire-and-forget sink for one-off Realtime usage telemetry.
///
/// This exists solely to answer whether moving the greeting on-device is
/// worth it (a two-week cost measurement). It is not a product feature: a
/// conforming reporter must never throw, retry, block the caller, or affect
/// the voice path in any way. Dropping a report is an acceptable gap for a
/// short sample, not a bug.
public protocol OpenAIRealtimeUsageReporting: Sendable {
    func report(_ usage: OpenAIRealtimeResponseUsage, turn: Int) async
}

/// The smallest HTTP boundary needed by the usage reporter.
///
/// Mirrors `VercelOpenAIRealtimeClientSecretDataLoader`: the production
/// implementation delegates to URLSession, and package tests inject an
/// in-memory double so no network operation is needed.
protocol OpenAIRealtimeUsageReportDataLoader: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Posts integer-only Realtime usage counts to the broker's `/api/usage`.
///
/// Authentication reuses the same device-authorization bearer token as
/// `VercelOpenAIRealtimeClientSecretSource`. Every failure — missing token,
/// storage error, network failure, timeout, non-2xx — is swallowed here and
/// never reaches the voice path: this type never throws. No retry, no
/// queueing, no buffering.
public actor OpenAIRealtimeUsageReporter: OpenAIRealtimeUsageReporting, Sendable {
    private let endpointURL: URL
    private let store: any DeviceAuthorizationStore
    private let dataLoader: any OpenAIRealtimeUsageReportDataLoader

    /// Creates a production reporter backed by the supplied URLSession.
    public init(
        endpointURL: URL,
        store: any DeviceAuthorizationStore,
        session: URLSession = .shared
    ) {
        self.init(
            endpointURL: endpointURL,
            store: store,
            dataLoader: OpenAIRealtimeUsageReportURLSessionDataLoader(session: session)
        )
    }

    /// Creates a reporter around an injected seam for deterministic package tests.
    init(
        endpointURL: URL,
        store: any DeviceAuthorizationStore,
        dataLoader: any OpenAIRealtimeUsageReportDataLoader
    ) {
        self.endpointURL = endpointURL
        self.store = store
        self.dataLoader = dataLoader
    }

    public func report(_ usage: OpenAIRealtimeResponseUsage, turn: Int) async {
        let token: DeviceAuthorizationToken?
        do {
            token = try await store.load()
        } catch {
            return
        }
        guard let token else { return }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(token.rawValue)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "turn": turn,
            "input_tokens": usage.inputTokens,
            "output_tokens": usage.outputTokens,
            "total_tokens": usage.totalTokens,
            "cached_input_tokens": usage.cachedInputTokens,
            "input_text_tokens": usage.inputTextTokens,
            "input_audio_tokens": usage.inputAudioTokens,
            "output_text_tokens": usage.outputTextTokens,
            "output_audio_tokens": usage.outputAudioTokens,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return
        }
        request.httpBody = bodyData

        _ = try? await dataLoader.data(for: request)
    }
}

/// Foundation URLSession implementation of the usage-report loader seam.
private struct OpenAIRealtimeUsageReportURLSessionDataLoader:
    OpenAIRealtimeUsageReportDataLoader,
    Sendable
{
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
