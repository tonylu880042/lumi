import Testing
@testable import LumiApp
import LumiApplication
import LumiInfrastructure

@Suite("Simulator voice control capabilities")
struct SimulatorControlCapabilitiesTests {
    @Test("Mock model renders start plus all four artificial voice controls")
    @MainActor
    func mockModelRendersArtificialControls() {
        let hardware = MockHardwareControlPort()
        let identity = MockIdentityRecognitionAdapter()
        let voice = MockVoiceSessionPort()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voiceSimulationControls: VoiceSimulationControls(voice: voice)
        )

        #expect(
            SimulatorControlCatalog.voiceControls(for: model)
                == [.startVoice, .userSpeechStarted, .userSpeechEnded, .responseReady, .voiceFailure]
        )
        #expect(
            SimulatorVoiceControl.startVoice.accessibilityHint(
                hasArtificialVoiceControls: model.hasArtificialVoiceControls
            ) == "啟動模擬語音工作階段"
        )
    }

    @Test("Live model renders start voice but no artificial voice controls")
    @MainActor
    func liveModelOmitsArtificialControls() {
        let hardware = MockHardwareControlPort()
        let identity = MockIdentityRecognitionAdapter()
        let voice = MockVoiceSessionPort()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let model = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voiceSimulationControls: nil
        )

        #expect(SimulatorControlCatalog.voiceControls(for: model) == [.startVoice])
        #expect(
            SimulatorVoiceControl.startVoice.accessibilityHint(
                hasArtificialVoiceControls: model.hasArtificialVoiceControls
            ) == "啟動語音工作階段"
        )
    }
}
