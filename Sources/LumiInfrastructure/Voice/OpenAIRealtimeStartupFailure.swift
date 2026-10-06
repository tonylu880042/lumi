import LumiApplication

/// Closed local diagnostic codes: never retain an underlying error, HTTP
/// payload, credential, identity or conversation content.
enum OpenAIRealtimeStartupFailure: String, Sendable {
    case authorizationRequired = "authorization-required"
    case brokerRateLimited = "broker-rate-limited"
    case brokerTransport = "broker-transport"
    case brokerResponse = "broker-response"
    case brokerCredential = "broker-credential"
    case microphoneDenied = "microphone-denied"
    case audioSession = "audio-session"
    case peer
    case signalingRejected = "signaling-rejected"
    case signaling
    case transport
    case endedBeforeReady = "ended-before-ready"
    case unclassified

    init(classifying error: any Error) {
        if error is VoiceSessionAuthorizationError {
            self = .authorizationRequired
        } else if let error = error as? VercelOpenAIRealtimeClientSecretSourceError {
            switch error {
            case .rateLimited: self = .brokerRateLimited
            case .transportFailure: self = .brokerTransport
            case .nonHTTPResponse, .responseFailure: self = .brokerResponse
            default: self = .brokerCredential
            }
        } else if let error = error as? OpenAIWebRTCTransportError {
            switch error {
            case .microphonePermissionDenied: self = .microphoneDenied
            case .audioSessionFailure: self = .audioSession
            case .peerFailure: self = .peer
            case .signalingRejected: self = .signalingRejected
            case .signalingFailure, .invalidRemoteDescription: self = .signaling
            case .expiredClientSecret: self = .brokerCredential
            case .dataChannelUnavailable, .transportFailure, .closed: self = .transport
            }
        } else if let error = error as? OpenAIRealtimeAdapterError,
                  error == .connectionEndedBeforeReady {
            self = .endedBeforeReady
        } else {
            self = .unclassified
        }
    }
}

enum OpenAIRealtimeStartupEvent: String {
    case credentialsRequested = "credentials-requested"
    case credentialsReady = "credentials-ready"
    case transportConnecting = "transport-connecting"
    case transportConnected = "transport-connected"
    case activationRequested = "activation-requested"
    case activationReady = "activation-ready"
    case providerReady = "provider-ready"
    case outputStarted = "output-started"
}
