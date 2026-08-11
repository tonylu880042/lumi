import SwiftUI
import LumiApplication
import LumiInfrastructure

@main
struct LumiAppApp: App {
    @StateObject private var simulationModel: SessionSimulationModel

    init() {
        let hardware = MockHardwareControlPort()
        let identity = MockIdentityRecognitionAdapter()
        let voice = MockVoiceSessionPort()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        _simulationModel = StateObject(
            wrappedValue: SessionSimulationModel(
                coordinator: coordinator,
                hardware: hardware,
                identity: identity,
                voice: voice
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(simulationModel: simulationModel)
                .preferredColorScheme(.light)
        }
    }
}
