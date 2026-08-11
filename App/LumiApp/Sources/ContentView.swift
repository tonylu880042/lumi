import SwiftUI
import LumiDomain
import LumiPresentation
import LumiUI

/// Full-screen Avatar host. Simulator controls stay in an overlay so they do
/// not change the fixed Avatar canvas or own any hardware/session state.
@MainActor
struct ContentView: View {
    @ObservedObject private var simulationModel: SessionSimulationModel

    @State private var controlsMode: SimulatorControlMode = .session
    @State private var direction: PresenceDirection = .center
    @State private var identityChoice: SessionSimulationModel.VisitorIdentityChoice = .unknown
    @State private var tuningSelection = 0
    @State private var eventSelection = 0
    @State private var triggeredEvent: AvatarEventCommand?
    @State private var sessionTriggeredEvent: AvatarEventCommand?
    @State private var cancelEvent = false
    @State private var sessionCancelEvent = false
    @State private var rawAmplitude = 0.0
    @State private var amplitudeProcessor = AmplitudeProcessor()
    @State private var processedAmplitude = 0.0
    @State private var controlsExpanded = false

    private let mapper = AvatarStateMapper()

    init(simulationModel: SessionSimulationModel) {
        self._simulationModel = ObservedObject(wrappedValue: simulationModel)
    }

    private var renderedAvatarState: AvatarVisualState {
        switch controlsMode {
        case .session:
            simulationModel.avatarState
        case .avatar:
            mapper.map(SimulatorControlCatalog.tuningStates[tuningSelection].state)
        }
    }

    private var renderedAmplitude: Double {
        controlsMode == .avatar ? processedAmplitude : 0
    }

    private var renderedEvent: Binding<AvatarEventCommand?> {
        controlsMode == .session ? $sessionTriggeredEvent : $triggeredEvent
    }

    var body: some View {
        ZStack(alignment: .top) {
            AvatarTokens.background
                .ignoresSafeArea()

            AnimatedLumiAvatarView(
                state: renderedAvatarState,
                processedAmplitude: renderedAmplitude,
                triggeredEvent: renderedEvent,
                cancelEvent: controlsMode == .avatar ? $cancelEvent : $sessionCancelEvent
            )
            .id(controlsMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                SimulatorControlsView(
                    simulationModel: simulationModel,
                    controlsExpanded: $controlsExpanded,
                    controlsMode: $controlsMode,
                    direction: $direction,
                    identityChoice: $identityChoice,
                    tuningSelection: $tuningSelection,
                    eventSelection: $eventSelection,
                    triggeredEvent: $triggeredEvent,
                    cancelEvent: $cancelEvent,
                    rawAmplitude: $rawAmplitude,
                    processedAmplitude: $processedAmplitude
                )
            }
        }
        .onChange(of: rawAmplitude) { _, newValue in
            processedAmplitude = amplitudeProcessor.process([newValue])
        }
        .onChange(of: controlsMode) { _, newMode in
            // Tuning events and amplitude never leak into coordinator mode.
            triggeredEvent = nil
            cancelEvent = false

            if newMode == .session {
                sessionCancelEvent = false
                sessionTriggeredEvent = simulationModel.consumeAvatarEvent()
            } else {
                sessionCancelEvent = false
                sessionTriggeredEvent = nil
            }
        }
        .onChange(of: simulationModel.assistantState) { _, newState in
            guard newState == .idle else { return }

            // A completed return-home is the only boundary that resets the
            // Session controls and immediately cancels its played Event.
            direction = .center
            identityChoice = .unknown
            sessionTriggeredEvent = nil
            if controlsMode == .session {
                sessionCancelEvent = true
            }
        }
        .onChange(of: simulationModel.pendingAvatarEvent) { _, newEvent in
            guard controlsMode == .session, let newEvent else { return }
            sessionTriggeredEvent = newEvent
            _ = simulationModel.consumeAvatarEvent()
        }
    }
}
