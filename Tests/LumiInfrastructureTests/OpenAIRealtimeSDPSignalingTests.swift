import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LumiInfrastructure
import Testing

@Suite("OpenAI Realtime SDP signaling")
struct OpenAIRealtimeSDPSignalingTests {
    @Test("posts the exact offer bytes with the ephemeral-token request contract")
    func sendsExactRequest() async throws {
        let offer = "v=0\r\n\u{5728} offer-🦙\r\n"
        let answer = "v=0\r\nanswer\r\n"
        let token = "ephemeral-token-marker"
        let loader = RecordingSDPDataLoader(
            result: .success((
                Data(answer.utf8),
                httpResponse(statusCode: 201)
            ))
        )
        let client = OpenAIRealtimeSDPSignalingClient(dataLoader: loader)
        let secret = try OpenAIRealtimeClientSecret(
            value: token,
            expiresAt: Date(timeIntervalSince1970: 1_234_567)
        )

        let receivedAnswer = try await client.exchange(
            offerSDP: offer,
            clientSecret: secret
        )

        #expect(receivedAnswer == answer)
        let request = await loader.lastRequest
        #expect(request?.url == URL(string: "https://api.openai.com/v1/realtime/calls"))
        #expect(request?.httpMethod == "POST")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/sdp")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(request?.httpBody == Data(offer.utf8))
    }

    @Test("rejects non-HTTP responses without exposing response details")
    func rejectsNonHTTPResponse() async throws {
        let offer = "offer-sensitive-marker"
        let answer = "answer-sensitive-marker"
        let token = "token-sensitive-marker"
        let loader = RecordingSDPDataLoader(
            result: .success((Data(answer.utf8), URLResponse()))
        )
        let client = OpenAIRealtimeSDPSignalingClient(dataLoader: loader)
        let secret = try OpenAIRealtimeClientSecret(
            value: token,
            expiresAt: Date(timeIntervalSince1970: 1_234_567)
        )

        let error = await thrownError {
            try await client.exchange(offerSDP: offer, clientSecret: secret)
        }

        #expect(error == .nonHTTPResponse)
        assertRedacted(error, markers: [offer, answer, token])
    }

    @Test("rejects every non-2xx status while preserving only its numeric code")
    func rejectsNonSuccessStatus() async throws {
        let statuses = [199, 300, 401, 500]

        for status in statuses {
            let loader = RecordingSDPDataLoader(
                result: .success((
                    Data("response-body-marker".utf8),
                    httpResponse(statusCode: status)
                ))
            )
            let client = OpenAIRealtimeSDPSignalingClient(dataLoader: loader)
            let secret = try OpenAIRealtimeClientSecret(
                value: "token-marker",
                expiresAt: Date(timeIntervalSince1970: 1_234_567)
            )

            let error = await thrownError {
                try await client.exchange(offerSDP: "offer-marker", clientSecret: secret)
            }

            #expect(error == .httpStatus(statusCode: status))
            assertRedacted(error, markers: ["token-marker", "offer-marker", "response-body-marker"])
        }
    }

    @Test("rejects an empty or whitespace-only UTF-8 answer")
    func rejectsEmptyAnswers() async throws {
        for answer in ["", " ", "\n\t  "] {
            let loader = RecordingSDPDataLoader(
                result: .success((Data(answer.utf8), httpResponse(statusCode: 201)))
            )
            let client = OpenAIRealtimeSDPSignalingClient(dataLoader: loader)
            let secret = try OpenAIRealtimeClientSecret(
                value: "token-marker",
                expiresAt: Date(timeIntervalSince1970: 1_234_567)
            )

            let error = await thrownError {
                try await client.exchange(offerSDP: "offer-marker", clientSecret: secret)
            }

            #expect(error == .emptyAnswer)
        }
    }

    @Test("returns any non-whitespace UTF-8 answer without SDP heuristics")
    func leavesRemoteDescriptionValidationToPeerDriver() async throws {
        let answer = "opaque-answer-for-peer-driver"
        let loader = RecordingSDPDataLoader(
            result: .success((Data(answer.utf8), httpResponse(statusCode: 200)))
        )
        let client = OpenAIRealtimeSDPSignalingClient(dataLoader: loader)
        let secret = try OpenAIRealtimeClientSecret(
            value: "token-marker",
            expiresAt: Date(timeIntervalSince1970: 1_234_567)
        )

        let receivedAnswer = try await client.exchange(
            offerSDP: "offer-marker",
            clientSecret: secret
        )

        #expect(receivedAnswer == answer)
    }

    @Test("rejects a successful response whose answer is not UTF-8")
    func rejectsInvalidUTF8Answer() async throws {
        let loader = RecordingSDPDataLoader(
            result: .success((Data([0x76, 0x3d, 0xff, 0xfe]), httpResponse(statusCode: 200)))
        )
        let client = OpenAIRealtimeSDPSignalingClient(dataLoader: loader)
        let secret = try OpenAIRealtimeClientSecret(
            value: "token-marker",
            expiresAt: Date(timeIntervalSince1970: 1_234_567)
        )

        let error = await thrownError {
            try await client.exchange(offerSDP: "offer-marker", clientSecret: secret)
        }

        #expect(error == .invalidUTF8Answer)
        assertRedacted(error, markers: ["token-marker", "offer-marker"])
    }

    @Test("preserves cancellation semantics and lets the loader observe cancellation")
    func cancellationIsNotMappedToProviderError() async throws {
        let loader = BlockingSDPDataLoader()
        let client = OpenAIRealtimeSDPSignalingClient(dataLoader: loader)
        let secret = try OpenAIRealtimeClientSecret(
            value: "token-marker",
            expiresAt: Date(timeIntervalSince1970: 1_234_567)
        )

        let exchange = Task {
            try await client.exchange(offerSDP: "offer-marker", clientSecret: secret)
        }
        await waitUntil { await loader.hasRequest }

        exchange.cancel()
        await #expect(throws: CancellationError.self) {
            try await exchange.value
        }
        await waitUntil { await loader.cancellationCount > 0 }
    }

    @Test("maps loader failures to a concise redacted error")
    func mapsLoaderFailureWithoutSensitiveDiagnostics() async throws {
        let token = "token-sensitive-marker"
        let offer = "offer-sensitive-marker"
        let loader = RecordingSDPDataLoader(
            result: .failure(SensitiveLoaderError(
                description: "raw body answer-sensitive-marker \(token) \(offer)"
            ))
        )
        let client = OpenAIRealtimeSDPSignalingClient(dataLoader: loader)
        let secret = try OpenAIRealtimeClientSecret(
            value: token,
            expiresAt: Date(timeIntervalSince1970: 1_234_567)
        )

        let error = await thrownError {
            try await client.exchange(offerSDP: offer, clientSecret: secret)
        }

        #expect(error == .transportFailure)
        assertRedacted(error, markers: [token, offer, "answer-sensitive-marker"])
    }
}

private actor RecordingSDPDataLoader: OpenAIRealtimeSDPDataLoader {
    private let result: Result<(Data, URLResponse), any Error>
    private(set) var lastRequest: URLRequest?

    init(result: Result<(Data, URLResponse), any Error>) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        return try result.get()
    }
}

private actor BlockingSDPDataLoader: OpenAIRealtimeSDPDataLoader {
    private(set) var hasRequest = false
    private(set) var cancellationCount = 0

    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        hasRequest = true
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw SensitiveLoaderError(description: "unexpected completion")
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }
}

private struct SensitiveLoaderError: Error, CustomStringConvertible, Sendable {
    let description: String
}

private func httpResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://api.openai.com/v1/realtime/calls")!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
}

private func thrownError(
    _ operation: () async throws -> String
) async -> OpenAIRealtimeSDPSignalingError {
    do {
        _ = try await operation()
        Issue.record("Expected signaling operation to throw")
        return .transportFailure
    } catch let error as OpenAIRealtimeSDPSignalingError {
        return error
    } catch {
        Issue.record("Unexpected error: \(error)")
        return .transportFailure
    }
}

private func assertRedacted(
    _ error: OpenAIRealtimeSDPSignalingError,
    markers: [String]
) {
    let diagnostics = [
        String(describing: error),
        String(reflecting: error),
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
    for _ in 0 ..< 100 {
        if await condition() { return }
        await Task.yield()
    }
}
