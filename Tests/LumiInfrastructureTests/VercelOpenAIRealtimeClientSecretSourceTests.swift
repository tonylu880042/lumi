import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LumiApplication
@testable import LumiInfrastructure
import Testing

@Suite("Vercel OpenAI Realtime client-secret source")
struct VercelOpenAIRealtimeClientSecretSourceTests {
    private let endpoint = URL(string: "https://broker.example.test/api/realtime/client-secret?endpoint-marker=private")!
    private let tokenValue = String(repeating: "A", count: 43)
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("loads the token and sends the exact bodyless broker request")
    func sendsExactRequestAndMapsSuccess() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: tokenValue))
        let store = RecordingDeviceAuthorizationStore(token: token)
        let loader = RecordingVercelClientSecretDataLoader(
            result: .success(
                Data(#"{"value":"client-secret-marker","expiresAt":1700000100}"#.utf8),
                httpResponse(statusCode: 200, url: endpoint)
            )
        )
        let source = makeSource(store: store, loader: loader)
        let configuration = OpenAIRealtimeConfiguration(
            model: "model-marker",
            voice: "voice-marker",
            instructions: "instructions-marker"
        )

        let secret = try await source.clientSecret(for: configuration)

        #expect(secret.value == "client-secret-marker")
        #expect(secret.expiresAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(await store.loadCallCount == 1)
        #expect(await store.removeCallCount == 0)

        let request = await loader.lastRequest
        #expect(request?.url == endpoint)
        #expect(request?.httpMethod == "POST")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer \(tokenValue)")
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request?.httpBody == nil)
        #expect(request?.httpBodyStream == nil)
        #expect(request?.allHTTPHeaderFields?.count == 2)
        #expect(request?.httpBody?.description.contains("model-marker") != true)
        #expect(request?.httpBody?.description.contains("voice-marker") != true)
        #expect(request?.httpBody?.description.contains("instructions-marker") != true)
    }

    @Test("missing authorization fails before making a broker request")
    func missingTokenRequiresAuthorization() async throws {
        let store = RecordingDeviceAuthorizationStore(token: nil)
        let loader = RecordingVercelClientSecretDataLoader(result: .failure(.unexpected))
        let source = makeSource(store: store, loader: loader)

        await #expect(throws: VoiceSessionAuthorizationError.authorizationRequired) {
            try await source.clientSecret(for: OpenAIRealtimeConfiguration())
        }

        #expect(await loader.requestCount == 0)
        #expect(await store.removeCallCount == 0)
    }

    @Test("maps a storage failure without exposing its marker")
    func mapsStorageFailure() async throws {
        let marker = "storage-marker"
        let store = RecordingDeviceAuthorizationStore(
            loadError: SensitiveStoreError(marker: marker)
        )
        let loader = RecordingVercelClientSecretDataLoader(result: .failure(.unexpected))
        let source = makeSource(store: store, loader: loader)

        let error = await thrownError {
            try await source.clientSecret(for: OpenAIRealtimeConfiguration())
        }

        #expect(error == .authorizationStorageFailure)
        assertRedacted(error, markers: [marker])
        #expect(await loader.requestCount == 0)
        #expect(await store.removeCallCount == 0)
    }

    @Test("maps a store authorization error to storage failure")
    func mapsStoreAuthorizationErrorToStorageFailure() async throws {
        let store = AuthorizationErrorDeviceAuthorizationStore()
        let loader = RecordingVercelClientSecretDataLoader(result: .failure(.unexpected))
        let source = makeSource(store: store, loader: loader)

        let error = await thrownError {
            try await source.clientSecret(for: OpenAIRealtimeConfiguration())
        }

        #expect(error == .authorizationStorageFailure)
        #expect(await loader.requestCount == 0)
        #expect(await store.removeCallCount == 0)
    }

    @Test("maps missing, malformed, unknown, and revoked responses to authorization")
    func mapsAuthorizationStatuses() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: tokenValue))

        for status in [401, 403] {
            let store = RecordingDeviceAuthorizationStore(token: token)
            let loader = RecordingVercelClientSecretDataLoader(
                result: .success(
                    Data(#"{"error":{"code":"unauthorized","marker":"response-marker"}}"#.utf8),
                    httpResponse(statusCode: status, url: endpoint)
                )
            )
            let source = makeSource(store: store, loader: loader)

            let applicationError = await thrownApplicationAuthorizationError {
                try await source.clientSecret(for: OpenAIRealtimeConfiguration())
            }
            #expect(applicationError == .authorizationRequired)
            #expect(await store.removeCallCount == 0)
            assertRedacted(applicationError, markers: [tokenValue, "response-marker", endpoint.absoluteString])
        }
    }

    @Test("maps rate limits to a retryable fixed category without deleting authorization")
    func mapsRateLimit() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: tokenValue))
        let store = RecordingDeviceAuthorizationStore(token: token)
        let loader = RecordingVercelClientSecretDataLoader(
            result: .success(Data("rate-limit-response-marker".utf8), httpResponse(statusCode: 429, url: endpoint))
        )
        let source = makeSource(store: store, loader: loader)

        let error = await thrownError {
            try await source.clientSecret(for: OpenAIRealtimeConfiguration())
        }

        #expect(error == .rateLimited)
        assertRedacted(error, markers: [tokenValue, "rate-limit-response-marker", endpoint.absoluteString])
        #expect(await store.removeCallCount == 0)
    }

    @Test("maps every non-200 non-authorization response to a fixed response failure")
    func mapsNonSuccessStatuses() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: tokenValue))

        for status in [199, 201, 204, 400, 404, 500, 502, 503] {
            let store = RecordingDeviceAuthorizationStore(token: token)
            let loader = RecordingVercelClientSecretDataLoader(
                result: .success(Data("status-body-marker".utf8), httpResponse(statusCode: status, url: endpoint))
            )
            let source = makeSource(store: store, loader: loader)

            let error = await thrownError {
                try await source.clientSecret(for: OpenAIRealtimeConfiguration())
            }

            #expect(error == .responseFailure)
            assertRedacted(error, markers: [tokenValue, "status-body-marker", endpoint.absoluteString])
            #expect(await store.removeCallCount == 0)
        }
    }

    @Test("rejects a non-HTTP response without exposing response details")
    func rejectsNonHTTPResponse() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: tokenValue))
        let store = RecordingDeviceAuthorizationStore(token: token)
        let loader = RecordingVercelClientSecretDataLoader(
            result: .success(Data("non-http-body-marker".utf8), URLResponse())
        )
        let source = makeSource(store: store, loader: loader)

        let error = await thrownError {
            try await source.clientSecret(for: OpenAIRealtimeConfiguration())
        }

        #expect(error == .nonHTTPResponse)
        assertRedacted(error, markers: [tokenValue, "non-http-body-marker", endpoint.absoluteString])
        #expect(await store.removeCallCount == 0)
    }

    @Test("maps transport failures to a fixed redacted category")
    func mapsTransportFailure() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: tokenValue))
        let store = RecordingDeviceAuthorizationStore(token: token)
        let loader = RecordingVercelClientSecretDataLoader(
            result: .failure(.sensitiveTransport)
        )
        let source = makeSource(store: store, loader: loader)

        let error = await thrownError {
            try await source.clientSecret(for: OpenAIRealtimeConfiguration())
        }

        #expect(error == .transportFailure)
        assertRedacted(error, markers: [tokenValue, "transport-body-marker", endpoint.absoluteString])
        #expect(await store.removeCallCount == 0)
    }

    @Test("rejects invalid UTF-8 and malformed JSON")
    func rejectsInvalidEncodingAndJSON() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: tokenValue))

        let responses: [(Data, VercelOpenAIRealtimeClientSecretSourceError)] = [
            (Data([0x7B, 0xFF, 0x7D]), .invalidUTF8Response),
            (Data("not-json-response-marker".utf8), .invalidJSON),
        ]

        for (data, expected) in responses {
            let store = RecordingDeviceAuthorizationStore(token: token)
            let loader = RecordingVercelClientSecretDataLoader(
                result: .success(data, httpResponse(statusCode: 200, url: endpoint))
            )
            let source = makeSource(store: store, loader: loader)

            let error = await thrownError {
                try await source.clientSecret(for: OpenAIRealtimeConfiguration())
            }

            #expect(error == expected)
            assertRedacted(error, markers: [tokenValue, "not-json-response-marker", endpoint.absoluteString])
            #expect(await store.removeCallCount == 0)
        }
    }

    @Test("rejects missing, empty, and invalid credential fields")
    func rejectsInvalidCredentialFields() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: tokenValue))
        let responses: [(String, VercelOpenAIRealtimeClientSecretSourceError)] = [
            (#"{"expiresAt":1700000100}"#, .missingValue),
            (#"{"value":"","expiresAt":1700000100}"#, .emptyValue),
            (#"{"value":123,"expiresAt":1700000100}"#, .invalidJSON),
            (#"{"value":"client-secret-marker"}"#, .missingExpiry),
            (#"{"value":"client-secret-marker","expiresAt":"not-a-number"}"#, .invalidExpiry),
            (#"{"value":"client-secret-marker","expiresAt":true}"#, .invalidExpiry),
        ]

        for (body, expected) in responses {
            let store = RecordingDeviceAuthorizationStore(token: token)
            let loader = RecordingVercelClientSecretDataLoader(
                result: .success(Data(body.utf8), httpResponse(statusCode: 200, url: endpoint))
            )
            let source = makeSource(store: store, loader: loader)

            let error = await thrownError {
                try await source.clientSecret(for: OpenAIRealtimeConfiguration())
            }

            #expect(error == expected)
            assertRedacted(error, markers: [tokenValue, "client-secret-marker", endpoint.absoluteString])
            #expect(await store.removeCallCount == 0)
        }
    }

    @Test("rejects non-finite and non-future expirations")
    func rejectsInvalidExpirations() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: tokenValue))
        let bodies: [(String, VercelOpenAIRealtimeClientSecretSourceError)] = [
            (#"{"value":"client-secret-marker","expiresAt":-1}"#, .expired),
            (#"{"value":"client-secret-marker","expiresAt":1700000000}"#, .expired),
            (#"{"value":"client-secret-marker","expiresAt":1e999}"#, .invalidJSON),
        ]

        for (body, expected) in bodies {
            let store = RecordingDeviceAuthorizationStore(token: token)
            let loader = RecordingVercelClientSecretDataLoader(
                result: .success(Data(body.utf8), httpResponse(statusCode: 200, url: endpoint))
            )
            let source = makeSource(store: store, loader: loader)

            let error = await thrownError {
                try await source.clientSecret(for: OpenAIRealtimeConfiguration())
            }

            #expect(error == expected)
            #expect(await store.removeCallCount == 0)
        }
    }

    @Test("preserves cancellation from the token store and avoids the network")
    func preservesStoreCancellation() async throws {
        let store = BlockingDeviceAuthorizationStore()
        let loader = RecordingVercelClientSecretDataLoader(result: .failure(.unexpected))
        let source = makeSource(store: store, loader: loader)
        let operation = Task {
            try await source.clientSecret(for: OpenAIRealtimeConfiguration())
        }

        await waitUntil { await store.hasPendingLoad }
        operation.cancel()

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(await store.cancellationCount > 0)
        #expect(await loader.requestCount == 0)
        #expect(await store.removeCallCount == 0)
    }

    @Test("preserves cancellation through the data loader")
    func preservesLoaderCancellation() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: tokenValue))
        let store = RecordingDeviceAuthorizationStore(token: token)
        let loader = BlockingVercelClientSecretDataLoader()
        let source = makeSource(store: store, loader: loader)
        let operation = Task {
            try await source.clientSecret(for: OpenAIRealtimeConfiguration())
        }

        await waitUntil { await loader.hasRequest }
        operation.cancel()

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        await waitUntil { await loader.cancellationCount > 0 }
        #expect(await store.removeCallCount == 0)
    }

    private func makeSource(
        store: any DeviceAuthorizationStore,
        loader: any VercelOpenAIRealtimeClientSecretDataLoader
    ) -> VercelOpenAIRealtimeClientSecretSource {
        VercelOpenAIRealtimeClientSecretSource(
            endpointURL: endpoint,
            store: store,
            dataLoader: loader,
            clock: { now }
        )
    }
}

private actor RecordingDeviceAuthorizationStore: DeviceAuthorizationStore {
    private let token: DeviceAuthorizationToken?
    private let loadError: SensitiveStoreError?
    private(set) var loadCallCount = 0
    private(set) var removeCallCount = 0

    init(
        token: DeviceAuthorizationToken? = nil,
        loadError: SensitiveStoreError? = nil
    ) {
        self.token = token
        self.loadError = loadError
    }

    func load() async throws -> DeviceAuthorizationToken? {
        loadCallCount += 1
        if let loadError { throw loadError }
        return token
    }

    func save(_: DeviceAuthorizationToken) async throws {}

    func remove() async throws {
        removeCallCount += 1
    }
}

private actor AuthorizationErrorDeviceAuthorizationStore: DeviceAuthorizationStore {
    private(set) var removeCallCount = 0

    func load() async throws -> DeviceAuthorizationToken? {
        throw VoiceSessionAuthorizationError.authorizationRequired
    }

    func save(_: DeviceAuthorizationToken) async throws {}

    func remove() async throws {
        removeCallCount += 1
    }
}

private actor BlockingDeviceAuthorizationStore: DeviceAuthorizationStore {
    private(set) var hasPendingLoad = false
    private(set) var cancellationCount = 0
    private(set) var removeCallCount = 0

    func load() async throws -> DeviceAuthorizationToken? {
        hasPendingLoad = true
        do {
            try await Task.sleep(for: .seconds(60))
            throw SensitiveStoreError(marker: "unexpected-store-completion")
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }

    func save(_: DeviceAuthorizationToken) async throws {}

    func remove() async throws {
        removeCallCount += 1
    }
}

private actor RecordingVercelClientSecretDataLoader: VercelOpenAIRealtimeClientSecretDataLoader {
    enum Result: Sendable {
        case success(Data, URLResponse)
        case failure(LoaderFailure)
    }

    enum LoaderFailure: Error, Sendable {
        case unexpected
        case sensitiveTransport
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
        case .success(let data, let response):
            return (data, response)
        case .failure(let error):
            switch error {
            case .unexpected:
                throw error
            case .sensitiveTransport:
                throw SensitiveLoaderError(marker: "transport-body-marker")
            }
        }
    }
}

private actor BlockingVercelClientSecretDataLoader: VercelOpenAIRealtimeClientSecretDataLoader {
    private(set) var hasRequest = false
    private(set) var cancellationCount = 0

    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        hasRequest = true
        do {
            try await Task.sleep(for: .seconds(60))
            throw SensitiveLoaderError(marker: "unexpected-loader-completion")
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }
}

private struct SensitiveStoreError: Error, Sendable {
    let marker: String
}

private struct SensitiveLoaderError: Error, Sendable {
    let marker: String
}

private func httpResponse(statusCode: Int, url: URL) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
}

private func thrownError(
    _ operation: () async throws -> OpenAIRealtimeClientSecret
) async -> VercelOpenAIRealtimeClientSecretSourceError? {
    do {
        _ = try await operation()
        Issue.record("Expected client-secret source operation to throw")
        return nil
    } catch let error as VercelOpenAIRealtimeClientSecretSourceError {
        return error
    } catch {
        Issue.record("Unexpected source error")
        return nil
    }
}

private func thrownApplicationAuthorizationError(
    _ operation: () async throws -> OpenAIRealtimeClientSecret
) async -> VoiceSessionAuthorizationError? {
    do {
        _ = try await operation()
        Issue.record("Expected client-secret source operation to throw")
        return nil
    } catch let error as VoiceSessionAuthorizationError {
        return error
    } catch {
        Issue.record("Unexpected source error")
        return nil
    }
}

private func assertRedacted<E: Error>(_ error: E?, markers: [String]) {
    guard let error else { return }
    let diagnostics = [
        String(describing: error),
        String(reflecting: error),
        String(describing: Mirror(reflecting: error)),
    ]
    for diagnostic in diagnostics {
        for marker in markers {
            #expect(!diagnostic.contains(marker))
        }
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0 ..< 200 {
        if await condition() { return }
        await Task.yield()
    }
}
