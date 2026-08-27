/// Product-owned audio-session values used by the injected Infrastructure seam.
///
/// These values deliberately do not expose AVFoundation or WebRTC types. That
/// keeps the test seam available to the macOS package build while the iOS
/// adapter below performs the framework-specific translation.
enum OpenAIRealtimeAudioSessionCategory: Equatable, Sendable {
    case playAndRecord
}

enum OpenAIRealtimeAudioSessionMode: Equatable, Sendable {
    case voiceChat
}

struct OpenAIRealtimeAudioSessionOptions: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let defaultToSpeaker = Self(rawValue: 1 << 0)
    static let allowBluetoothHFP = Self(rawValue: 1 << 1)
}

/// Public WebRTC configuration policy kept separate from AVFoundation types so
/// the route contract can be verified by the macOS package tests.
enum OpenAIRealtimeWebRTCConfigurationPolicy {
    static func defaultRouteOptions(
        to existingOptions: OpenAIRealtimeAudioSessionOptions = []
    ) -> OpenAIRealtimeAudioSessionOptions {
        existingOptions.union([.defaultToSpeaker, .allowBluetoothHFP])
    }
}

struct OpenAIRealtimeAudioSessionIntent: Equatable, Sendable {
    let category: OpenAIRealtimeAudioSessionCategory
    let mode: OpenAIRealtimeAudioSessionMode
    let options: OpenAIRealtimeAudioSessionOptions

    init(
        category: OpenAIRealtimeAudioSessionCategory,
        mode: OpenAIRealtimeAudioSessionMode,
        options: OpenAIRealtimeAudioSessionOptions
    ) {
        self.category = category
        self.mode = mode
        self.options = options
    }

    static let voiceChat = Self(
        category: .playAndRecord,
        mode: .voiceChat,
        options: [.defaultToSpeaker, .allowBluetoothHFP]
    )
}

/// Errors that a concrete backend can classify without carrying framework
/// diagnostics across the Infrastructure boundary.
enum OpenAIRealtimeAudioSessionBackendError: Error, Equatable, Sendable {
    case category
    case mode
    case activation
}

/// Narrow, actor-safe boundary for an audio-session implementation.
///
/// `activate(configurationIntent:)` is one atomic backend operation. The iOS
/// implementation locks, configures, activates, and unlocks synchronously
/// inside that operation; callers never hold a framework lock over `await`.
protocol OpenAIRealtimeAudioSessionBackend: Sendable {
    /// Applies the final WebRTC route options before the backend activates the
    /// system audio session and creates its audio unit. The framework adapter
    /// maps these Infrastructure values to WebRTC's documented configuration
    /// setter; tests can record both the options and the ordering.
    func configureWebRTCDefaults(
        options: OpenAIRealtimeAudioSessionOptions
    ) async
    func activate(
        configurationIntent: OpenAIRealtimeAudioSessionIntent
    ) async throws
    func deactivate() async
}

/// Controller consumed by the Infrastructure transport lifecycle.
protocol OpenAIRealtimeAudioSessionController: Sendable {
    func activate() async throws
    func deactivate() async
}

/// Stable, privacy-safe failures for audio-session activation.
enum OpenAIRealtimeAudioSessionError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    enum ConfigurationStep: Equatable, Sendable {
        case category
        case mode
    }

    case configurationFailed(step: ConfigurationStep)
    case activationFailed

    var description: String {
        switch self {
        case .configurationFailed(let step):
            switch step {
            case .category:
                return "Audio-session category configuration failed."
            case .mode:
                return "Audio-session mode configuration failed."
            }
        case .activationFailed:
            return "Audio-session activation failed."
        }
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: ["reason": description], displayStyle: .enum)
    }
}

/// Actor-owned lifecycle wrapper for the Realtime voice audio session.
///
/// The wrapper makes activation idempotent and ensures deactivation is issued
/// at most once for each successful activation. A failed backend activation is
/// considered cleaned up by the backend, so a later close cannot issue a
/// second deactivation attempt.
actor OpenAIRealtimeAudioSession: OpenAIRealtimeAudioSessionController {
    private let backend: any OpenAIRealtimeAudioSessionBackend
    private var isActive = false
    private var cleanupPerformed = false

    init(backend: any OpenAIRealtimeAudioSessionBackend) {
        self.backend = backend
    }

    #if os(iOS)
    init() {
        self.backend = OpenAIRealtimeRTCAudioSessionBackend()
    }
    #endif

    func activate() async throws {
        guard !isActive else { return }

        do {
            let intent = OpenAIRealtimeAudioSessionIntent(
                category: .playAndRecord,
                mode: .voiceChat,
                options: OpenAIRealtimeWebRTCConfigurationPolicy.defaultRouteOptions()
            )
            await backend.configureWebRTCDefaults(options: intent.options)
            try await backend.activate(
                configurationIntent: intent
            )
            isActive = true
            cleanupPerformed = false
        } catch let error as OpenAIRealtimeAudioSessionBackendError {
            cleanupPerformed = true
            throw map(error)
        } catch {
            // Do not carry framework or provider diagnostics into callers.
            cleanupPerformed = true
            throw OpenAIRealtimeAudioSessionError.activationFailed
        }
    }

    func deactivate() async {
        guard isActive, !cleanupPerformed else { return }

        // Mark this before awaiting the backend so concurrent close calls are
        // harmless even if framework cleanup takes time.
        isActive = false
        cleanupPerformed = true
        await backend.deactivate()
    }

    private func map(
        _ error: OpenAIRealtimeAudioSessionBackendError
    ) -> OpenAIRealtimeAudioSessionError {
        switch error {
        case .category:
            return .configurationFailed(step: .category)
        case .mode:
            return .configurationFailed(step: .mode)
        case .activation:
            return .activationFailed
        }
    }
}

#if os(iOS)
import AVFoundation
import WebRTC

/// iOS-only RTCAudioSession adapter.
///
/// The WebRTC framework singleton is accessed only here. Every operation that
/// requires configuration uses one synchronous lock/set/unlock scope, and no
/// speaker override is used: `defaultToSpeaker` expresses the preferred route
/// only when an external route is absent while HFP remains available.
private actor OpenAIRealtimeRTCAudioSessionBackend:
    OpenAIRealtimeAudioSessionBackend
{
    private let audioSession: RTCAudioSession

    init(audioSession: RTCAudioSession = RTCAudioSession.sharedInstance()) {
        self.audioSession = audioSession
    }

    func activate(
        configurationIntent intent: OpenAIRealtimeAudioSessionIntent
    ) async throws {
        audioSession.lockForConfiguration()
        defer { audioSession.unlockForConfiguration() }

        do {
            try audioSession.setCategory(
                avCategory(for: intent.category),
                with: avOptions(for: intent.options)
            )
        } catch {
            throw OpenAIRealtimeAudioSessionBackendError.category
        }

        do {
            try audioSession.setMode(avMode(for: intent.mode))
        } catch {
            throw OpenAIRealtimeAudioSessionBackendError.mode
        }

        configureDirectionalInput(on: audioSession.session)

        do {
            try audioSession.setActive(true)
        } catch {
            // Activation can fail after the system has partially changed
            // state. Balance the intent before releasing the configuration
            // lock; cleanup errors are intentionally not surfaced here.
            try? audioSession.setActive(false)
            throw OpenAIRealtimeAudioSessionBackendError.activation
        }
    }

    private func configureDirectionalInput(on session: AVAudioSession) {
        try? session.setPreferredInputOrientation(.portrait)

        guard let inputs = session.availableInputs else { return }
        for input in inputs where input.portType == .builtInMic {
            if let dataSources = input.dataSources {
                if let frontSource = dataSources.first(where: {
                    $0.orientation == .front || $0.dataSourceName.localizedCaseInsensitiveContains("Front")
                }) {
                    if let patterns = frontSource.supportedPolarPatterns, patterns.contains(.cardioid) {
                        try? frontSource.setPreferredPolarPattern(.cardioid)
                    }
                    try? input.setPreferredDataSource(frontSource)
                }
            }
            try? audioSession.setPreferredInput(input)
            break
        }
    }

    /// WebRTC creates/configures its audio unit after the app's AVAudioSession
    /// activation. Set the documented WebRTC default configuration first so
    /// that its later configure step retains the product route preference.
    func configureWebRTCDefaults(
        options: OpenAIRealtimeAudioSessionOptions
    ) async {
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.categoryOptions.insert(avOptions(for: options))
        RTCAudioSessionConfiguration.setWebRTC(configuration)
    }

    func deactivate() async {
        audioSession.lockForConfiguration()
        defer { audioSession.unlockForConfiguration() }
        try? audioSession.setActive(false)
    }

    private func avCategory(
        for category: OpenAIRealtimeAudioSessionCategory
    ) -> AVAudioSession.Category {
        switch category {
        case .playAndRecord:
            return .playAndRecord
        }
    }

    private func avMode(
        for mode: OpenAIRealtimeAudioSessionMode
    ) -> AVAudioSession.Mode {
        switch mode {
        case .voiceChat:
            return .voiceChat
        }
    }

    private func avOptions(
        for options: OpenAIRealtimeAudioSessionOptions
    ) -> AVAudioSession.CategoryOptions {
        var result: AVAudioSession.CategoryOptions = []
        if options.contains(.defaultToSpeaker) {
            result.insert(.defaultToSpeaker)
        }
        if options.contains(.allowBluetoothHFP) {
            result.insert(.allowBluetoothHFP)
        }
        return result
    }
}
#endif
