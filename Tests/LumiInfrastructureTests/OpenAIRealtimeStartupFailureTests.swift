import Foundation
import LumiApplication
@testable import LumiInfrastructure
import Testing

@Suite("Realtime startup diagnostics privacy")
struct OpenAIRealtimeStartupFailureTests {
    @Test("Startup failures distinguish broker, audio and connection boundaries")
    func classifiesKnownFailures() {
        #expect(OpenAIRealtimeStartupFailure(classifying:
            VercelOpenAIRealtimeClientSecretSourceError.rateLimited) == .brokerRateLimited)
        #expect(OpenAIRealtimeStartupFailure(classifying:
            VercelOpenAIRealtimeClientSecretSourceError.transportFailure) == .brokerTransport)
        #expect(OpenAIRealtimeStartupFailure(classifying:
            VercelOpenAIRealtimeClientSecretSourceError.responseFailure) == .brokerResponse)
        #expect(OpenAIRealtimeStartupFailure(classifying:
            VoiceSessionAuthorizationError.authorizationRequired) == .authorizationRequired)
        #expect(OpenAIRealtimeStartupFailure(classifying:
            OpenAIWebRTCTransportError.microphonePermissionDenied) == .microphoneDenied)
        #expect(OpenAIRealtimeStartupFailure(classifying:
            OpenAIWebRTCTransportError.audioSessionFailure) == .audioSession)
        #expect(OpenAIRealtimeStartupFailure(classifying:
            OpenAIWebRTCTransportError.peerFailure) == .peer)
        #expect(OpenAIRealtimeStartupFailure(classifying:
            OpenAIWebRTCTransportError.signalingRejected(statusCode: 401)) == .signalingRejected)
        #expect(OpenAIRealtimeStartupFailure(classifying:
            OpenAIRealtimeAdapterError.connectionEndedBeforeReady) == .endedBeforeReady)
    }

    @Test("Arbitrary errors and signaling payloads cannot enter diagnostics")
    func doesNotRetainArbitraryPayloads() {
        let error = NSError(domain: "secret-token-and-member-name", code: 42,
                            userInfo: [NSLocalizedDescriptionKey: "private conversation"])
        let diagnostic = OpenAIRealtimeStartupFailure(classifying: error)
        #expect(diagnostic == .unclassified)
        #expect(diagnostic.rawValue == "unclassified")
        #expect(Mirror(reflecting: diagnostic).children.isEmpty)
        #expect(OpenAIRealtimeStartupFailure(classifying:
            OpenAIWebRTCTransportError.signalingRejected(statusCode: Int.max)).rawValue
            == "signaling-rejected")
    }
}
