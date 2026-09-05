import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LumiApplication

/// The smallest HTTP boundary needed by the broker credential source.
///
/// The production implementation delegates to URLSession. Package tests
/// inject an in-memory actor so no network or credential operation is needed.
protocol VercelOpenAIRealtimeClientSecretDataLoader: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Fixed, privacy-safe failures from the broker credential source.
enum VercelOpenAIRealtimeClientSecretSourceError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case authorizationStorageFailure
    case nonHTTPResponse
    case rateLimited
    case responseFailure
    case invalidUTF8Response
    case invalidJSON
    case missingValue
    case emptyValue
    case missingExpiry
    case invalidExpiry
    case expired
    case transportFailure

    var description: String {
        switch self {
        case .authorizationStorageFailure:
            "Device authorization storage failed."
        case .nonHTTPResponse:
            "The broker returned a non-HTTP response."
        case .rateLimited:
            "The broker rate limit was reached."
        case .responseFailure:
            "The broker returned an unsuccessful response."
        case .invalidUTF8Response:
            "The broker returned an invalid UTF-8 response."
        case .invalidJSON:
            "The broker returned an invalid JSON response."
        case .missingValue:
            "The broker response omitted the client secret."
        case .emptyValue:
            "The broker response contained an empty client secret."
        case .missingExpiry:
            "The broker response omitted the expiration time."
        case .invalidExpiry:
            "The broker response contained an invalid expiration time."
        case .expired:
            "The broker response contained an expired credential."
        case .transportFailure:
            "The broker request failed."
        }
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: ["reason": description], displayStyle: .enum)
    }
}

/// Supplies an ephemeral OpenAI Realtime credential through the Vercel broker.
///
/// The broker request is deliberately bodyless. The supplied Realtime
/// configuration is consumed by the existing provider adapter after the
/// credential is returned and never crosses this device-authorization
/// boundary.
public actor VercelOpenAIRealtimeClientSecretSource:
    OpenAIRealtimeClientSecretSource,
    Sendable
{
    private let endpointURL: URL
    private let store: any DeviceAuthorizationStore
    private let dataLoader: any VercelOpenAIRealtimeClientSecretDataLoader
    private let clock: @Sendable () -> Date
    private var cachedSecret: OpenAIRealtimeClientSecret?

    /// Creates a production source backed by the supplied URLSession.
    public init(
        endpointURL: URL,
        store: any DeviceAuthorizationStore,
        session: URLSession = .shared
    ) {
        self.init(
            endpointURL: endpointURL,
            store: store,
            dataLoader: VercelOpenAIRealtimeURLSessionDataLoader(session: session),
            clock: { Date() }
        )
    }

    /// Creates a source around injected seams for deterministic package tests.
    init(
        endpointURL: URL,
        store: any DeviceAuthorizationStore,
        dataLoader: any VercelOpenAIRealtimeClientSecretDataLoader,
        clock: @escaping @Sendable () -> Date
    ) {
        self.endpointURL = endpointURL
        self.store = store
        self.dataLoader = dataLoader
        self.clock = clock
    }

    /// Loads the current device token and mints one short-lived credential.
    public func clientSecret(
        for _: OpenAIRealtimeConfiguration
    ) async throws -> OpenAIRealtimeClientSecret {
        let currentTime = clock()
        if let cachedSecret, cachedSecret.expiresAt > currentTime.addingTimeInterval(30) {
            return cachedSecret
        }

        try Task.checkCancellation()
        let token = try await loadToken()
        try Task.checkCancellation()

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(token.rawValue)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = nil

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
            throw VercelOpenAIRealtimeClientSecretSourceError.transportFailure
        }
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VercelOpenAIRealtimeClientSecretSourceError.nonHTTPResponse
        }

        guard httpResponse.statusCode == 200 else {
            switch httpResponse.statusCode {
            case 401, 403:
                throw VoiceSessionAuthorizationError.authorizationRequired
            case 429:
                throw VercelOpenAIRealtimeClientSecretSourceError.rateLimited
            default:
                throw VercelOpenAIRealtimeClientSecretSourceError.responseFailure
            }
        }

        let secret = try decodeSecret(from: data)
        self.cachedSecret = secret
        return secret
    }

    private func loadToken() async throws -> DeviceAuthorizationToken {
        let token: DeviceAuthorizationToken?
        do {
            token = try await store.load()
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw VercelOpenAIRealtimeClientSecretSourceError.authorizationStorageFailure
        }

        guard let token else {
            throw VoiceSessionAuthorizationError.authorizationRequired
        }
        return token
    }

    private func decodeSecret(
        from data: Data
    ) throws -> OpenAIRealtimeClientSecret {
        guard String(data: data, encoding: .utf8) != nil else {
            throw VercelOpenAIRealtimeClientSecretSourceError.invalidUTF8Response
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw VercelOpenAIRealtimeClientSecretSourceError.invalidJSON
        }

        guard let envelope = object as? [String: Any] else {
            throw VercelOpenAIRealtimeClientSecretSourceError.invalidJSON
        }

        guard envelope["value"] != nil else {
            throw VercelOpenAIRealtimeClientSecretSourceError.missingValue
        }
        guard let value = envelope["value"] as? String else {
            throw VercelOpenAIRealtimeClientSecretSourceError.invalidJSON
        }
        guard !value.isEmpty else {
            throw VercelOpenAIRealtimeClientSecretSourceError.emptyValue
        }

        guard envelope["expiresAt"] != nil else {
            throw VercelOpenAIRealtimeClientSecretSourceError.missingExpiry
        }
        guard let number = envelope["expiresAt"] as? NSNumber,
              !(envelope["expiresAt"] is Bool) else {
            throw VercelOpenAIRealtimeClientSecretSourceError.invalidExpiry
        }

        let unixSeconds = number.doubleValue
        guard unixSeconds.isFinite else {
            throw VercelOpenAIRealtimeClientSecretSourceError.invalidExpiry
        }

        let currentUnixSeconds = clock().timeIntervalSince1970
        guard unixSeconds > currentUnixSeconds else {
            throw VercelOpenAIRealtimeClientSecretSourceError.expired
        }

        return try OpenAIRealtimeClientSecret(
            value: value,
            expiresAt: Date(timeIntervalSince1970: unixSeconds)
        )
    }
}

/// Foundation URLSession implementation of the broker loader seam.
private struct VercelOpenAIRealtimeURLSessionDataLoader:
    VercelOpenAIRealtimeClientSecretDataLoader,
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
