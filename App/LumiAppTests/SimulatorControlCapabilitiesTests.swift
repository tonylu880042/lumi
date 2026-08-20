import Foundation
import Testing
@testable import LumiApp
import LumiApplication
import LumiInfrastructure

@Suite("Simulator voice control capabilities")
struct SimulatorControlCapabilitiesTests {
    @Test("Conversation direction picker stays inside the Debug-Live boundary")
    func conversationDirectionPickerIsDebugLiveOnly() throws {
        let controlsSource = try source(named: "SimulatorControlsView.swift")
        let contentSource = try source(named: "ContentView.swift")
        let modelSource = try source(named: "SessionSimulationModel.swift")

        #expect(controlsSource.contains("#if DEBUG && LUMI_LIVE"))
        #expect(controlsSource.contains("ConversationDirectionChoice"))
        #expect(modelSource.contains("運動前提醒"))
        #expect(modelSource.contains("運動後 review"))
        #expect(!controlsSource.contains("import LumiApplication"))
        #expect(!contentSource.contains("import LumiApplication"))
        #expect(contentSource.contains("conversationDirectionChoice: $conversationDirectionChoice"))
    }

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

    private func source(named fileName: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LumiApp/Sources")
            .appendingPathComponent(fileName)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
