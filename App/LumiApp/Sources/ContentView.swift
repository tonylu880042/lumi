import SwiftUI
import LumiDomain
import LumiPresentation
import LumiUI

/// Full-screen Avatar host. Simulator controls stay in an overlay so they do
/// not change the fixed Avatar canvas or own any hardware/session state.
@MainActor
struct ContentView: View {
    @ObservedObject private var simulationModel: SessionSimulationModel

    @AppStorage(LumiHomeViewIntent.hintsStorageKey)
    private var showsApplicationHints = LumiHomeViewIntent.showsHintsByDefault
    @State private var isHomeSettingsPresented = false

#if DEBUG
    private let calibrationModel: DebugIdentityCalibrationModel?
    @State private var isCalibrationPresented = false
#endif

    @State private var controlsMode: SimulatorControlMode = .session
    @State private var direction: PresenceDirection = .center
    @State private var identityChoice: SessionSimulationModel.VisitorIdentityChoice = .unknown
    @State private var conversationDirectionChoice: SessionSimulationModel.ConversationDirectionChoice = .general
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
#if DEBUG
        self.calibrationModel = nil
#endif
    }

#if DEBUG
    init(
        simulationModel: SessionSimulationModel,
        calibrationModel: DebugIdentityCalibrationModel
    ) {
        self._simulationModel = ObservedObject(wrappedValue: simulationModel)
        self.calibrationModel = calibrationModel
    }

    static func shouldShowCalibrationEntry(
        hasCalibrationModel: Bool,
        supportsContinuousExperience: Bool
    ) -> Bool {
        hasCalibrationModel && !supportsContinuousExperience
    }
#endif

    private var renderedAvatarState: AvatarVisualState {
        switch controlsMode {
        case .session:
            if simulationModel.supportsContinuousExperience,
               simulationModel.isContinuousExperienceRunning,
               simulationModel.assistantState == .idle {
                mapper.map(.recognizing)
            } else {
                simulationModel.avatarState
            }
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
            .overlay(alignment: AppOverlayLayout.sessionControls.alignment) {
                if !simulationModel.supportsContinuousExperience {
                    SimulatorControlsView(
                        simulationModel: simulationModel,
                        controlsExpanded: $controlsExpanded,
                        controlsMode: $controlsMode,
                        direction: $direction,
                        identityChoice: $identityChoice,
                        conversationDirectionChoice: $conversationDirectionChoice,
                        tuningSelection: $tuningSelection,
                        eventSelection: $eventSelection,
                        triggeredEvent: $triggeredEvent,
                        cancelEvent: $cancelEvent,
                        rawAmplitude: $rawAmplitude,
                        processedAmplitude: $processedAmplitude
                    )
                }
            }

            if simulationModel.supportsContinuousExperience {
                LumiHomeOverlay(
                    status: simulationModel.recognitionDisplayStatus,
                    greeting: simulationModel.visitorGreeting,
                    enrolledMemberCount: simulationModel.enrolledMemberCount,
                    showsApplicationHints: showsApplicationHints,
                    openSettings: {
                        isHomeSettingsPresented = true
                    }
                )
            }

            if simulationModel.supportsContinuousExperience,
               let errorMessage = simulationModel.errorMessage {
                VStack(spacing: 12) {
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                    Button(
                        simulationModel.canStartVoiceSession
                            ? "重新啟動語音"
                            : "重新開始辨識"
                    ) {
                        if simulationModel.canStartVoiceSession {
                            simulationModel.startVoiceSession()
                        } else {
                            Task {
                                await simulationModel.restartContinuousExperience()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 24)
                .padding(.top, 72)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
#if DEBUG
            if Self.shouldShowCalibrationEntry(
                hasCalibrationModel: calibrationModel != nil,
                supportsContinuousExperience: simulationModel.supportsContinuousExperience
            ) {
                Button {
                    isCalibrationPresented = true
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                }
                .buttonStyle(.bordered)
                .padding(16)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .bottomLeading
                )
                .accessibilityLabel("DEBUG 身份校準")
                .accessibilityIdentifier("debug-identity-calibration")
            }
#endif
        }
        .sheet(isPresented: $isHomeSettingsPresented) {
            LumiHomeSettingsView(
                showsApplicationHints: $showsApplicationHints
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
#if DEBUG
        .sheet(isPresented: $isCalibrationPresented) {
            if let calibrationModel {
                DebugIdentityCalibrationView(model: calibrationModel)
            }
        }
#endif
        .task {
            simulationModel.startContinuousExperience()
        }
        .onDisappear {
            simulationModel.stopContinuousExperience()
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
            conversationDirectionChoice = .general
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
