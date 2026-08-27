import SwiftUI
import LumiApplication
import LumiDomain
import LumiInfrastructure
import LumiPresentation

/// The non-view result of composing one compile-time App graph.
///
/// A Mock destination contains only deterministic in-process adapters. A Live
/// destination retains the one setup model that both root routing and the
/// semantic authorization callback use. An unavailable destination contains
/// only static copy and therefore cannot initialize authorization or voice
/// dependencies.
@MainActor
enum AppCompositionDestination {
    case mock(simulationModel: SessionSimulationModel)
    case live(
        setupModel: DeviceSetupModel,
        simulationModel: SessionSimulationModel
    )
    case unavailable(message: String)
}

/// Builds App destinations from a pure plan.
///
/// The closure is an App-internal test seam. Production uses the explicit
/// builder below; tests can record invocation and return a deterministic graph
/// without touching Keychain, network, WebRTC, or microphone services.
@MainActor
struct AppCompositionFactory {
    typealias Builder = @MainActor (AppCompositionPlan) -> AppCompositionDestination

    private let builder: Builder

    init(builder: Builder? = nil) {
        self.builder = builder ?? Self.productionBuilder
    }

    func make(plan: AppCompositionPlan) -> AppCompositionDestination {
        switch plan {
        case let .unavailable(message):
            // Configuration failure is resolved before this seam; no builder
            // is invoked, so it cannot construct a Mock fallback or Keychain.
            return .unavailable(message: message)
        case .mock, .live:
            return builder(plan)
        }
    }

    private static func productionBuilder(
        _ plan: AppCompositionPlan
    ) -> AppCompositionDestination {
        switch plan {
        case .mock:
            return makeMockDestination()
        case let .live(environment, brokerEndpoint):
            return makeLiveDestination(
                brokerEndpoint: brokerEndpoint,
                keychainService: AppRuntimeConfiguration.keychainService(for: environment)
            )
        case let .unavailable(message):
            return .unavailable(message: message)
        }
    }

    private static func makeMockDestination() -> AppCompositionDestination {
        let hardware = MockHardwareControlPort()
        let identity = MockIdentityRecognitionAdapter()
        let voice = MockVoiceSessionPort()
        let coordinator = AssistantSessionCoordinator(
            hardware: hardware,
            identity: identity,
            voice: voice
        )
        let simulationModel = SessionSimulationModel(
            coordinator: coordinator,
            hardware: hardware,
            identity: identity,
            voiceSimulationControls: VoiceSimulationControls(voice: voice)
        )
        return .mock(simulationModel: simulationModel)
    }

    private static func makeLiveDestination(
        brokerEndpoint: URL,
        keychainService: String
    ) -> AppCompositionDestination {
        do {
            // The service namespace comes only from the validated pure plan.
            // Every App root receives a fresh store and fresh voice graph.
            let store = try KeychainDeviceAuthorizationStore(service: keychainService)
            let controller = DeviceAuthorizationController(store: store)
            let setupModel = DeviceSetupModel(controller: controller)
            let source = VercelOpenAIRealtimeClientSecretSource(
                endpointURL: brokerEndpoint,
                store: store
            )
            let voiceConfiguration: OpenAIRealtimeConfiguration
            let voiceToolCallConfiguration: VoiceToolCallSessionConfiguration?
            let visitorEnrollmentToolCallConfiguration:
                VisitorEnrollmentToolCallSessionConfiguration?
            let enablesWeeklySummaryTool: Bool
            let enablesVisitorEnrollmentTools: Bool
#if DEBUG
            let repository = try DebugMemberFixture.makeRepository()
            voiceConfiguration = OpenAIRealtimeConfiguration()
            enablesWeeklySummaryTool = true
            enablesVisitorEnrollmentTools = true
#else
            voiceConfiguration = OpenAIRealtimeConfiguration()
            enablesWeeklySummaryTool = false
            enablesVisitorEnrollmentTools = false
#endif
            let voice = OpenAIRealtimeAdapter(
                configuration: voiceConfiguration,
                clientSecretSource: source,
                transportFactory: OpenAIWebRTCTransportFactory(),
                enablesWeeklySummaryTool: enablesWeeklySummaryTool,
                enablesVisitorEnrollmentTools: enablesVisitorEnrollmentTools
            )

#if DEBUG
            voiceToolCallConfiguration = VoiceToolCallSessionConfiguration(
                port: voice,
                weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                    repository: repository
                )
            )
            let identityServiceLoader = AppCoreMLIdentityServiceLoader()
            let visitorEnrollment = AppVisitorEnrollmentPortProxy {
                try await identityServiceLoader.load()
            }
            visitorEnrollmentToolCallConfiguration =
                VisitorEnrollmentToolCallSessionConfiguration(
                    port: voice,
                    enrollmentPort: visitorEnrollment
                )
#else
            voiceToolCallConfiguration = nil
            visitorEnrollmentToolCallConfiguration = nil
#endif

            let hardware = MockHardwareControlPort()
#if DEBUG
            let identity = AppPilotIdentityRecognitionComposition.makePort {
                let service = try await identityServiceLoader.load()
                return PilotIdentityRecognitionAdapter(source: service)
            }
            let visitorPresence = AppVisitorPresenceMonitoringPortProxy {
                let service = try await identityServiceLoader.load()
                return PilotVisitorPresenceMonitor(
                    source: service,
                    departureAbsenceDuration: .seconds(10)
                )
            }
            let memberAddressResolver:
                @Sendable (MemberID) async -> VoiceMemberAddress? = { memberID in
                    if let storedAddress = try? await visitorEnrollment.address(
                        for: memberID
                    ) {
                        return storedAddress
                    }
                    return AppPilotIdentityRecognitionComposition
                        .voiceMemberAddress(for: memberID)
                }
            let coordinator = AssistantSessionCoordinator(
                hardware: hardware,
                identity: identity,
                voice: voice,
                memberAddressResolver: memberAddressResolver,
                voiceToolCallConfiguration: voiceToolCallConfiguration,
                visitorEnrollmentToolCallConfiguration:
                    visitorEnrollmentToolCallConfiguration
            )
            let simulationModel = SessionSimulationModel(
                coordinator: coordinator,
                hardware: hardware,
                voiceSimulationControls: nil,
                memberAddressResolver: memberAddressResolver,
                visitorPresenceMonitor: visitorPresence,
                identityEnrollmentSummary: identityServiceLoader,
                onAuthorizationRequired: {
                    setupModel.authorizationInvalidated()
                }
            )
#else
            let identity = MockIdentityRecognitionAdapter()
            let coordinator = AssistantSessionCoordinator(
                hardware: hardware,
                identity: identity,
                voice: voice,
                voiceToolCallConfiguration: voiceToolCallConfiguration
            )
            let simulationModel = SessionSimulationModel(
                coordinator: coordinator,
                hardware: hardware,
                identity: identity,
                voiceSimulationControls: nil,
                onAuthorizationRequired: {
                    setupModel.authorizationInvalidated()
                }
            )
#endif
            return .live(
                setupModel: setupModel,
                simulationModel: simulationModel
            )
        } catch {
            // A validated plan should always contain one of the approved
            // service names. Keep this boundary fail-closed if that invariant
            // changes rather than attempting Mock voice as a fallback.
            return .unavailable(
                message: AppRuntimeConfiguration.liveUnavailableMessage
            )
        }
    }
}

@main
@MainActor
struct LumiAppApp: App {
    private let destination: AppCompositionDestination

    init() {
        let plan = AppRuntimeConfiguration.compositionPlan()
        destination = AppCompositionFactory().make(plan: plan)
    }

    var body: some Scene {
        WindowGroup {
            destinationView
                .modifier(AppDisplayWakeModifier())
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch destination {
        case let .mock(simulationModel):
            MockCompositionRootView(simulationModel: simulationModel)
        case let .live(setupModel, simulationModel):
            LiveCompositionRootView(
                setupModel: setupModel,
                simulationModel: simulationModel
            )
        case let .unavailable(message):
            AppCompositionUnavailableView(message: message)
        }
    }
}

/// Mock owns its session model directly and deliberately never enters setup
/// routing or loads device authorization.
@MainActor
private struct MockCompositionRootView: View {
    @StateObject private var simulationModel: SessionSimulationModel
#if DEBUG
    @State private var calibrationModel: DebugIdentityCalibrationModel
#endif

    init(simulationModel: SessionSimulationModel) {
        _simulationModel = StateObject(wrappedValue: simulationModel)
#if DEBUG
        _calibrationModel = State(
            initialValue: AppIdentityCalibrationComposition.makeModel()
        )
#endif
    }

    var body: some View {
#if DEBUG
        ContentView(
            simulationModel: simulationModel,
            calibrationModel: calibrationModel
        )
        .preferredColorScheme(.light)
#else
        ContentView(simulationModel: simulationModel)
            .preferredColorScheme(.light)
#endif
    }
}

/// Live retains each root model exactly once. The task guard is set before the
/// asynchronous load begins, preventing repeated uncontrolled loads if SwiftUI
/// recreates the task after a view update.
@MainActor
private struct LiveCompositionRootView: View {
    @State private var setupModel: DeviceSetupModel
    @StateObject private var simulationModel: SessionSimulationModel
    @State private var hasStartedSetupLoad = false
#if DEBUG
    @State private var calibrationModel: DebugIdentityCalibrationModel
#endif

    init(
        setupModel: DeviceSetupModel,
        simulationModel: SessionSimulationModel
    ) {
        _setupModel = State(initialValue: setupModel)
        _simulationModel = StateObject(wrappedValue: simulationModel)
#if DEBUG
        _calibrationModel = State(
            initialValue: AppIdentityCalibrationComposition.makeModel()
        )
#endif
    }

    var body: some View {
        AppRootView(setupModel: setupModel) {
#if DEBUG
            ContentView(
                simulationModel: simulationModel,
                calibrationModel: calibrationModel
            )
#else
            ContentView(simulationModel: simulationModel)
#endif
        }
        .task {
            guard !hasStartedSetupLoad else { return }
            hasStartedSetupLoad = true
            await setupModel.load()
        }
    }
}

/// Independent fail-closed screen. It has no `DeviceSetupView` or
/// `SecureField`, so invalid Live configuration cannot prompt for a token or
/// touch Keychain state.
@MainActor
struct AppCompositionUnavailableView: View {
    let message: String

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(24)
        }
        .preferredColorScheme(.light)
    }
}
