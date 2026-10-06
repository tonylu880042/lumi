import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LumiApplication
@testable import LumiInfrastructure
import Testing

@Suite("OpenAI Realtime usage reporter")
struct OpenAIRealtimeUsageReporterTests {
    private let endpoint = URL(string: "https://broker.example.test/api/usage")!
    private let tokenValue = String(repeating: "A", count: 43)

    private let sampleUsage = OpenAIRealtimeResponseUsage(
        inputTokens: 45,
        outputTokens: 78,
        totalTokens: 123,
        cachedInputTokens: 5,
        inputTextTokens: 10,
        inputAudioTokens: 35,
        outputTextTokens: 20,
        outputAudioTokens: 58
    )

    @Test("sends the exact bearer-authenticated request with integer-only fields")
    func sendsExactRequest() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: tokenValue))
        let store = RecordingUsageAuthorizationStore(token: token)
        let loader = RecordingUsageReportDataLoader(result: .success)
        let reporter = OpenAIRealtimeUsageReporter(
            endpointURL: endpoint,
            store: store,
            dataLoader: loader
        )

        await reporter.report(sampleUsage, turn: 3)

        #expect(await loader.requestCount == 1)
        let request = await loader.lastRequest
        #expect(request?.url == endpoint)
        #expect(request?.httpMethod == "POST")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer \(tokenValue)")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request?.httpBody)
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["turn"] as? Int == 3)
        #expect(object["input_tokens"] as? Int == 45)
        #expect(object["output_tokens"] as? Int == 78)
        #expect(object["total_tokens"] as? Int == 123)
        #expect(object["cached_input_tokens"] as? Int == 5)
        #expect(object["input_text_tokens"] as? Int == 10)
        #expect(object["input_audio_tokens"] as? Int == 35)
        #expect(object["output_text_tokens"] as? Int == 20)
        #expect(object["output_audio_tokens"] as? Int == 58)
        #expect(object.count == 9)
    }

    @Test("a missing device token never sends a request")
    func missingTokenSkipsRequest() async {
        let store = RecordingUsageAuthorizationStore(token: nil)
        let loader = RecordingUsageReportDataLoader(result: .success)
        let reporter = OpenAIRealtimeUsageReporter(
            endpointURL: endpoint,
            store: store,
            dataLoader: loader
        )

        await reporter.report(sampleUsage, turn: 1)

        #expect(await loader.requestCount == 0)
    }

    @Test("a storage failure is swallowed and never throws")
    func storageFailureIsSwallowed() async {
        let store = FailingUsageAuthorizationStore()
        let loader = RecordingUsageReportDataLoader(result: .success)
        let reporter = OpenAIRealtimeUsageReporter(
            endpointURL: endpoint,
            store: store,
            dataLoader: loader
        )

        await reporter.report(sampleUsage, turn: 1)

        #expect(await loader.requestCount == 0)
    }

    @Test("network failures, timeouts, and non-2xx responses are all swallowed")
    func transportFailuresAreSwallowed() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: tokenValue))

        let throwingLoader = RecordingUsageReportDataLoader(result: .failure)
        let throwingReporter = OpenAIRealtimeUsageReporter(
            endpointURL: endpoint,
            store: RecordingUsageAuthorizationStore(token: token),
            dataLoader: throwingLoader
        )
        await throwingReporter.report(sampleUsage, turn: 1)
        #expect(await throwingLoader.requestCount == 1)

        let non2xxLoader = RecordingUsageReportDataLoader(result: .nonSuccessStatus)
        let non2xxReporter = OpenAIRealtimeUsageReporter(
            endpointURL: endpoint,
            store: RecordingUsageAuthorizationStore(token: token),
            dataLoader: non2xxLoader
        )
        await non2xxReporter.report(sampleUsage, turn: 1)
        #expect(await non2xxLoader.requestCount == 1)
    }
}

private actor RecordingUsageAuthorizationStore: DeviceAuthorizationStore {
    private let token: DeviceAuthorizationToken?

    init(token: DeviceAuthorizationToken?) {
        self.token = token
    }

    func load() async throws -> DeviceAuthorizationToken? { token }
    func save(_: DeviceAuthorizationToken) async throws {}
    func remove() async throws {}
}

private actor FailingUsageAuthorizationStore: DeviceAuthorizationStore {
    func load() async throws -> DeviceAuthorizationToken? {
        throw VoiceSessionAuthorizationError.authorizationRequired
    }

    func save(_: DeviceAuthorizationToken) async throws {}
    func remove() async throws {}
}

private actor RecordingUsageReportDataLoader: OpenAIRealtimeUsageReportDataLoader {
    enum Result: Sendable {
        case success
        case failure
        case nonSuccessStatus
    }

    private let result: Result
    private(set) var lastRequest: URLRequest?
    private(set) var requestCount = 0

    init(result: Result) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        lastRequest = request
        switch result {
        case .success:
            return (
                Data(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        case .failure:
            throw URLError(.timedOut)
        case .nonSuccessStatus:
            return (
                Data(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    }
}
