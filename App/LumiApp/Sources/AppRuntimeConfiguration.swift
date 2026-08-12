import Foundation

enum AppRuntimeEnvironment: String, Equatable, Sendable {
    case preview
    case production
}

enum AppRuntimeDescriptor: Equatable, Sendable {
    case mock
    case live(environment: AppRuntimeEnvironment, brokerEndpoint: URL)
}

/// Pure composition input. It contains only non-secret build configuration;
/// concrete stores, transports, and session models are created later by the
/// App composition root.
enum AppCompositionPlan: Equatable, Sendable {
    case mock
    case live(
        environment: AppRuntimeEnvironment,
        brokerEndpoint: URL
    )
    case unavailable(message: String)
}

enum AppRuntimeConfigurationError: Error, Equatable, Sendable {
    case missingBrokerEndpoint
    case malformedBrokerEndpoint
    case missingBrokerEnvironment
    case malformedBrokerEnvironment
}

enum AppRuntimeConfiguration {
    private static let endpointInfoKey = "LUMI_BROKER_ENDPOINT"
    private static let environmentInfoKey = "LUMI_BROKER_ENVIRONMENT"

    static let liveUnavailableMessage = "語音服務尚未完成設定，請聯絡管理員。"

    #if LUMI_LIVE
    private static let compileTimeIsLive = true
    #else
    private static let compileTimeIsLive = false
    #endif

    /// Resolves the app's compile-time mode and generated plist values.
    ///
    /// Live configuration is intentionally fail-closed. An absent or invalid
    /// endpoint never turns a Live build into the offline Mock composition.
    static func descriptor() throws -> AppRuntimeDescriptor {
        try descriptor(
            isLive: compileTimeIsLive,
            brokerEndpoint: Bundle.main.object(forInfoDictionaryKey: endpointInfoKey) as? String,
            brokerEnvironment: Bundle.main.object(forInfoDictionaryKey: environmentInfoKey) as? String
        )
    }

    /// Pure descriptor seam used by App composition tests and later wiring.
    static func descriptor(
        isLive: Bool,
        brokerEndpoint: String?,
        brokerEnvironment: String?
    ) throws -> AppRuntimeDescriptor {
        guard isLive else { return .mock }

        let endpoint = try validatedEndpoint(brokerEndpoint)
        let environment = try validatedEnvironment(brokerEnvironment)
        return .live(environment: environment, brokerEndpoint: endpoint)
    }

    /// Resolves the non-secret composition plan and fails closed for Live.
    /// Invalid Live configuration is intentionally represented as an
    /// unavailable destination rather than selecting the offline Mock graph.
    static func compositionPlan() -> AppCompositionPlan {
        compositionPlan(
            isLive: compileTimeIsLive,
            brokerEndpoint: Bundle.main.object(forInfoDictionaryKey: endpointInfoKey) as? String,
            brokerEnvironment: Bundle.main.object(forInfoDictionaryKey: environmentInfoKey) as? String
        )
    }

    /// Pure seam used by App tests to exercise both compile-time branches.
    static func compositionPlan(
        isLive: Bool,
        brokerEndpoint: String?,
        brokerEnvironment: String?
    ) -> AppCompositionPlan {
        do {
            let runtimeDescriptor = try descriptor(
                isLive: isLive,
                brokerEndpoint: brokerEndpoint,
                brokerEnvironment: brokerEnvironment
            )

            switch runtimeDescriptor {
            case .mock:
                return .mock
            case let .live(environment, brokerEndpoint):
                return .live(
                    environment: environment,
                    brokerEndpoint: brokerEndpoint
                )
            }
        } catch {
            return .unavailable(message: liveUnavailableMessage)
        }
    }

    static func keychainService(for environment: AppRuntimeEnvironment) -> String {
        switch environment {
        case .preview:
            "com.curves.lumi.live.preview"
        case .production:
            "com.curves.lumi.live.production"
        }
    }

    private static func validatedEndpoint(_ rawValue: String?) throws -> URL {
        guard let rawValue else {
            throw AppRuntimeConfigurationError.missingBrokerEndpoint
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppRuntimeConfigurationError.missingBrokerEndpoint
        }
        guard rawValue == trimmed,
              rawValue.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace }),
              let url = URL(string: rawValue),
              url.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else {
            throw AppRuntimeConfigurationError.malformedBrokerEndpoint
        }

        return url
    }

    private static func validatedEnvironment(_ rawValue: String?) throws -> AppRuntimeEnvironment {
        guard let rawValue else {
            throw AppRuntimeConfigurationError.missingBrokerEnvironment
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppRuntimeConfigurationError.missingBrokerEnvironment
        }
        guard rawValue == trimmed,
              let environment = AppRuntimeEnvironment(rawValue: rawValue)
        else {
            throw AppRuntimeConfigurationError.malformedBrokerEnvironment
        }

        return environment
    }
}
