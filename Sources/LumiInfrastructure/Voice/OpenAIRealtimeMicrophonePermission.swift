#if os(iOS)
import AVFAudio
#endif

/// Product-owned microphone authorization states.
///
/// Keeping these values independent of AVFAudio lets the transport and its
/// tests remain platform-neutral and prevents Apple framework types from
/// crossing the Infrastructure seam.
internal enum OpenAIRealtimeMicrophonePermissionStatus: Equatable, Sendable {
    case authorized
    case denied
    case undetermined
}

/// Privacy-safe failure returned when microphone input is not available.
internal enum OpenAIRealtimeMicrophonePermissionError: Error, Equatable, Sendable {
    case denied
}

/// Injectable microphone authorization boundary used by the Realtime
/// transport. A transport fake only needs to implement `authorize()`.
internal protocol OpenAIRealtimeMicrophonePermissionClient: Sendable {
    func authorize() async throws(OpenAIRealtimeMicrophonePermissionError)
}

/// Status/request seam used by the Apple adapter and deterministic policy
/// tests. It refines the transport-facing client so its default authorization
/// policy can be reused without exposing AVFAudio values.
internal protocol OpenAIRealtimeMicrophonePermissionStatusClient:
    OpenAIRealtimeMicrophonePermissionClient
{
    func currentStatus() async -> OpenAIRealtimeMicrophonePermissionStatus

    func requestPermission() async -> OpenAIRealtimeMicrophonePermissionStatus
}

extension OpenAIRealtimeMicrophonePermissionStatusClient {
    /// Allows an already-authorized client immediately, rejects an existing
    /// denial without requesting again, and requests exactly once when status
    /// is undetermined.
    func authorize() async throws(OpenAIRealtimeMicrophonePermissionError) {
        switch await currentStatus() {
        case .authorized:
            return
        case .denied:
            throw .denied
        case .undetermined:
            guard await requestPermission() == .authorized else {
                throw .denied
            }
        }
    }
}

#if os(iOS)
/// iOS 17+ microphone authorization adapter backed by AVAudioApplication.
///
/// This type intentionally does not use AVAudioSession's deprecated record
/// permission APIs. It is unavailable to macOS builds; package tests inject a
/// fake `OpenAIRealtimeMicrophonePermissionClient` instead.
@available(iOS 17.0, *)
internal struct OpenAIRealtimeMicrophonePermission:
    OpenAIRealtimeMicrophonePermissionStatusClient,
    Sendable
{
    private let application: AVAudioApplication

    internal init(application: AVAudioApplication = .shared) {
        self.application = application
    }

    internal func currentStatus() async -> OpenAIRealtimeMicrophonePermissionStatus {
        switch application.recordPermission {
        case .granted:
            return .authorized
        case .denied:
            return .denied
        case .undetermined:
            return .undetermined
        @unknown default:
            return .denied
        }
    }

    internal func requestPermission() async -> OpenAIRealtimeMicrophonePermissionStatus {
        let granted = await AVAudioApplication.requestRecordPermission()
        return granted ? .authorized : .denied
    }
}
#endif
