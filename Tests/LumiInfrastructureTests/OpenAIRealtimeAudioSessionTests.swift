@testable import LumiInfrastructure
import Testing

@Suite("OpenAI Realtime audio session")
struct OpenAIRealtimeAudioSessionTests {
    @Test("activation applies the exact voice-chat route intent while holding the lock")
    func activationUsesVoiceChatRoutePolicy() async throws {
        let backend = RecordingAudioSessionBackend()
        let audioSession = OpenAIRealtimeAudioSession(backend: backend)

        try await audioSession.activate()

        #expect(await backend.operations == [
            .configureWebRTCDefaults([.defaultToSpeaker, .allowBluetoothHFP]),
            .activate(
                OpenAIRealtimeAudioSessionIntent(
                    category: .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
            ),
        ])
        #expect(await backend.audioEnabledValues == [false, true])
        acceptsSendable(audioSession)
    }

    @Test("standby preparation keeps WebRTC audio disabled")
    func standbyPreparationDisablesWebRTCAudio() async {
        let backend = RecordingAudioSessionBackend()
        let audioSession = OpenAIRealtimeAudioSession(backend: backend)

        await audioSession.prepareForStandby()

        #expect(await backend.audioEnabledValues == [false])
        #expect(await backend.operations == [
            .configureWebRTCDefaults([.defaultToSpeaker, .allowBluetoothHFP]),
        ])
    }

    @Test("deactivation is ordered, idempotent, and never forces the speaker")
    func deactivationIsIdempotent() async throws {
        let backend = RecordingAudioSessionBackend()
        let audioSession = OpenAIRealtimeAudioSession(backend: backend)

        try await audioSession.activate()
        await audioSession.deactivate()
        await audioSession.deactivate()

        #expect(await backend.operations == [
            .configureWebRTCDefaults([.defaultToSpeaker, .allowBluetoothHFP]),
            .activate(
                OpenAIRealtimeAudioSessionIntent(
                    category: .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
            ),
            .deactivate,
        ])
        #expect(await backend.audioEnabledValues == [false, true, false])
        #expect(await backend.operations.contains(.deactivate))
    }

    @Test("activation failure maps to a privacy-safe typed error and avoids duplicate cleanup")
    func activationFailureCleansUpAndRedactsBackendError() async {
        let marker = "audio-session-secret-marker"
        let backend = RecordingAudioSessionBackend(failure: .activation(marker))
        let audioSession = OpenAIRealtimeAudioSession(backend: backend)

        await #expect(throws: OpenAIRealtimeAudioSessionError.activationFailed) {
            try await audioSession.activate()
        }

        #expect(await backend.operations == [
            .configureWebRTCDefaults([.defaultToSpeaker, .allowBluetoothHFP]),
            .activate(
                OpenAIRealtimeAudioSessionIntent(
                    category: .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
            ),
        ])
        #expect(await backend.audioEnabledValues == [false])

        await audioSession.deactivate()
        #expect(await backend.operations.filter { $0 == .deactivate }.count == 0)

        let error = OpenAIRealtimeAudioSessionError.activationFailed
        #expect(!String(describing: error).contains(marker))
        #expect(!String(reflecting: error).contains(marker))
    }

    @Test("cancellation after backend activation balances the backend session")
    func cancellationAfterBackendActivationDeactivatesBackend() async {
        let backend = RecordingAudioSessionBackend(blockActivationReturn: true)
        let audioSession = OpenAIRealtimeAudioSession(backend: backend)
        let activation = Task { try await audioSession.activate() }

        await backend.waitUntilActivationReturnIsBlocked()
        activation.cancel()
        await backend.releaseActivationReturn()

        await #expect(throws: CancellationError.self) {
            try await activation.value
        }
        #expect(await backend.operations.filter { $0 == .deactivate }.count == 1)
        #expect(await backend.audioEnabledValues == [false, false])
    }

    @Test("configuration failure maps to a typed category error")
    func configurationFailureUnlocks() async {
        let backend = RecordingAudioSessionBackend(failure: .configuration("category-marker"))
        let audioSession = OpenAIRealtimeAudioSession(backend: backend)

        await #expect(
            throws: OpenAIRealtimeAudioSessionError.configurationFailed(step: .category)
        ) {
            try await audioSession.activate()
        }

        #expect(await backend.operations == [
            .configureWebRTCDefaults([.defaultToSpeaker, .allowBluetoothHFP]),
            .activate(
                OpenAIRealtimeAudioSessionIntent(
                    category: .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
            ),
        ])
        #expect(await backend.audioEnabledValues == [false])
    }

    @Test("mode configuration failure maps safely without deactivation side effects")
    func modeConfigurationFailureMapsSafely() async {
        let marker = "mode-session-sensitive-marker"
        let backend = RecordingAudioSessionBackend(failure: .mode(marker))
        let audioSession = OpenAIRealtimeAudioSession(backend: backend)

        do {
            try await audioSession.activate()
            Issue.record("Expected mode configuration to fail")
        } catch let error as OpenAIRealtimeAudioSessionError {
            #expect(error == .configurationFailed(step: .mode))
            #expect(!String(describing: error).contains(marker))
            #expect(!String(reflecting: error).contains(marker))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await backend.operations == [
            .configureWebRTCDefaults([.defaultToSpeaker, .allowBluetoothHFP]),
            .activate(
                OpenAIRealtimeAudioSessionIntent(
                    category: .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
            ),
        ])
        #expect(await backend.audioEnabledValues == [false])
        await audioSession.deactivate()
        #expect(await backend.operations.contains(.deactivate) == false)
    }
}

private actor RecordingAudioSessionBackend: OpenAIRealtimeAudioSessionBackend {
    fileprivate enum Operation: Equatable, Sendable {
        case configureWebRTCDefaults(OpenAIRealtimeAudioSessionOptions)
        case activate(OpenAIRealtimeAudioSessionIntent)
        case deactivate
    }

    enum Failure: Error, Sendable {
        case configuration(String)
        case mode(String)
        case activation(String)
    }

    fileprivate(set) var operations: [Operation] = []
    fileprivate(set) var audioEnabledValues: [Bool] = []
    private let failure: Failure?
    private let blockActivationReturn: Bool
    private var activationReturnContinuation: CheckedContinuation<Void, Never>?
    private var activationReturnIsBlocked = false

    init(failure: Failure? = nil, blockActivationReturn: Bool = false) {
        self.failure = failure
        self.blockActivationReturn = blockActivationReturn
    }

    func configureWebRTCDefaults(
        options: OpenAIRealtimeAudioSessionOptions
    ) async {
        operations.append(.configureWebRTCDefaults(options))
        audioEnabledValues.append(false)
    }

    func setWebRTCAudioEnabled(_ enabled: Bool) async {
        audioEnabledValues.append(enabled)
    }

    func activate(configurationIntent: OpenAIRealtimeAudioSessionIntent) async throws {
        operations.append(.activate(configurationIntent))
        switch failure {
        case .configuration:
            throw OpenAIRealtimeAudioSessionBackendError.category
        case .mode:
            throw OpenAIRealtimeAudioSessionBackendError.mode
        case .activation:
            throw failure!
        case nil:
            break
        }
        if blockActivationReturn {
            activationReturnIsBlocked = true
            await withCheckedContinuation { continuation in
                activationReturnContinuation = continuation
            }
        }
    }

    func deactivate() async {
        operations.append(.deactivate)
    }

    func waitUntilActivationReturnIsBlocked() async {
        while !activationReturnIsBlocked {
            await Task.yield()
        }
    }

    func releaseActivationReturn() {
        activationReturnContinuation?.resume()
        activationReturnContinuation = nil
        activationReturnIsBlocked = false
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
