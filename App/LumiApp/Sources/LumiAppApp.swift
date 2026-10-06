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
        simulationModel: SessionSimulationModel,
        memberMemoryManagementModel: MemberMemoryManagementModel?
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

    struct VoiceToolCapabilities: Equatable, Sendable {
        let enablesWeeklySummaryTool: Bool
        let enablesVisitorEnrollmentTools: Bool
        let enablesMemberMemoryTool: Bool
    }

    private let builder: Builder

    init(builder: Builder? = nil) {
        self.builder = builder ?? Self.productionBuilder
    }

    /// Member interaction memory is an explicitly bounded Debug-Live pilot
    /// capability. Mock and Release compositions must not construct or expose
    /// its operator surface.
    static func memberMemoryManagementEnabled(for plan: AppCompositionPlan) -> Bool {
#if DEBUG && LUMI_LIVE
        if case .live = plan { return true }
#endif
        return false
    }

    /// Keeps synthetic exercise data out of the Debug-Live member-memory pilot.
    /// The capability plan is shared by composition and tests so a future Live
    /// wiring change cannot silently re-register the weekly-summary tool.
    static func voiceToolCapabilities(
        for plan: AppCompositionPlan
    ) -> VoiceToolCapabilities {
        guard case .live = plan else {
            return VoiceToolCapabilities(
                enablesWeeklySummaryTool: false,
                enablesVisitorEnrollmentTools: false,
                enablesMemberMemoryTool: false
            )
        }

#if DEBUG && LUMI_LIVE
        return VoiceToolCapabilities(
            enablesWeeklySummaryTool: false,
            enablesVisitorEnrollmentTools: true,
            enablesMemberMemoryTool: true
        )
#elseif DEBUG
        return VoiceToolCapabilities(
            enablesWeeklySummaryTool: true,
            enablesVisitorEnrollmentTools: true,
            enablesMemberMemoryTool: false
        )
#else
        return VoiceToolCapabilities(
            enablesWeeklySummaryTool: false,
            enablesVisitorEnrollmentTools: false,
            enablesMemberMemoryTool: false
        )
#endif
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
            let storeArrivalVitalityService = StoreArrivalVitalityService()
            let recordedGreeting = RecordedGreetingCoordinator(
                playback: RecordedVoicePlayback(
                    player: AVFoundationRecordedVoicePlayer()
                ),
                vitalityProvider: {
                    await storeArrivalVitalityService.currentVitality()
                }
            )
            let voiceConfiguration: OpenAIRealtimeConfiguration
            let voiceToolCallConfiguration: VoiceToolCallSessionConfiguration?
            let visitorEnrollmentToolCallConfiguration:
                VisitorEnrollmentToolCallSessionConfiguration?
            let voiceToolCapabilities = Self.voiceToolCapabilities(
                for: .live(
                    environment: .preview,
                    brokerEndpoint: brokerEndpoint
                )
            )
#if DEBUG
            let identityServiceLoader = AppCoreMLIdentityServiceLoader()
#if !LUMI_LIVE
            let repository = try DebugMemberFixture.makeRepository()
#endif
            voiceConfiguration = OpenAIRealtimeConfiguration(
                usesExternalGreeting: true,
                allowsConversationClosing: true
            )
#else
            voiceConfiguration = OpenAIRealtimeConfiguration(
                usesExternalGreeting: true,
                allowsConversationClosing: true
            )
#endif
            let voice = OpenAIRealtimeAdapter(
                configuration: voiceConfiguration,
                clientSecretSource: source,
                transportFactory: OpenAIWebRTCTransportFactory(),
                enablesWeeklySummaryTool:
                    voiceToolCapabilities.enablesWeeklySummaryTool,
                enablesVisitorEnrollmentTools:
                    voiceToolCapabilities.enablesVisitorEnrollmentTools,
                enablesMemberMemoryTool:
                    voiceToolCapabilities.enablesMemberMemoryTool,
                recordedGreeting: recordedGreeting
            )

#if DEBUG && !LUMI_LIVE
            voiceToolCallConfiguration = VoiceToolCallSessionConfiguration(
                port: voice,
                weeklySummaryUseCase: GetMemberWeeklySummaryUseCase(
                    repository: repository
                )
            )
#elseif DEBUG && LUMI_LIVE
            // The memory runner remains installed, but its weekly-summary
            // dependency is intentionally absent in the Debug-Live pilot.
            voiceToolCallConfiguration = VoiceToolCallSessionConfiguration(
                port: voice
            )
#else
            voiceToolCallConfiguration = nil
#endif

#if DEBUG
            let visitorEnrollment = AppVisitorEnrollmentPortProxy {
                try await identityServiceLoader.load()
            }
            visitorEnrollmentToolCallConfiguration =
                VisitorEnrollmentToolCallSessionConfiguration(
                    port: voice,
                    enrollmentPort: visitorEnrollment
                )
#else
            visitorEnrollmentToolCallConfiguration = nil
#endif

#if DEBUG && LUMI_LIVE
            guard let applicationSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw IdentityCalibrationError.failed
            }
            let memberMemoryDatabaseURL = try AppIdentityCalibrationComposition
                .prepareMemberMemoryDatabaseURL(
                    applicationSupportURL: applicationSupportURL,
                    fileManager: .default
                )
            let memberMemoryDirectoryURL = memberMemoryDatabaseURL
                .deletingLastPathComponent()
            try SQLiteMemberInteractionMemoryStoreMaintenance
                .excludeDirectoryFromBackup(directoryURL: memberMemoryDirectoryURL)
            let memberMemoryStore = try SQLiteMemberInteractionMemoryStore(
                databaseURL: memberMemoryDatabaseURL
            )
            let memberMemoryConfiguration:
                MemberInteractionMemorySessionConfiguration? =
                MemberInteractionMemorySessionConfiguration(store: memberMemoryStore)
            Task {
                try? await memberMemoryStore.pruneExpired(at: Date())
            }
#elseif DEBUG
            let memberMemoryConfiguration:
                MemberInteractionMemorySessionConfiguration? = nil
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
                    departureAbsenceDuration: .seconds(3)
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
                    visitorEnrollmentToolCallConfiguration,
                memberMemoryConfiguration: memberMemoryConfiguration
            )
            let simulationModel = SessionSimulationModel(
                coordinator: coordinator,
                hardware: hardware,
                voiceSimulationControls: nil,
                memberAddressResolver: memberAddressResolver,
                visitorPresenceMonitor: visitorPresence,
                storeArrivalVitalityService: storeArrivalVitalityService,
                identityEnrollmentSummary: identityServiceLoader,
                onAuthorizationRequired: {
                    setupModel.authorizationInvalidated()
                }
            )
#if LUMI_LIVE
            let memberMemoryManagementModel: MemberMemoryManagementModel? =
                MemberMemoryManagementModel(
                    store: memberMemoryStore,
                    directory: identityServiceLoader,
                    consentUseCase: SetMemberMemoryConsentUseCase(
                        store: memberMemoryStore
                    ),
                    clearUseCase: ClearMemberMemoryUseCase(
                        store: memberMemoryStore
                    ),
                    onBeforeMemoryMutation: {
                        await simulationModel.prepareForMemberMemoryMutation()
                    },
                    onAfterMemoryMutation: {
                        await simulationModel.restartContinuousExperience()
                    }
                )
#else
            let memberMemoryManagementModel: MemberMemoryManagementModel? = nil
#endif
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
                storeArrivalVitalityService: storeArrivalVitalityService,
                onAuthorizationRequired: {
                    setupModel.authorizationInvalidated()
                }
            )
            let memberMemoryManagementModel: MemberMemoryManagementModel? = nil
#endif
            return .live(
                setupModel: setupModel,
                simulationModel: simulationModel,
                memberMemoryManagementModel: memberMemoryManagementModel
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
        case let .live(setupModel, simulationModel, memberMemoryManagementModel):
            LiveCompositionRootView(
                setupModel: setupModel,
                simulationModel: simulationModel,
                memberMemoryManagementModel: memberMemoryManagementModel
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
    private let memberMemoryManagementModel: MemberMemoryManagementModel?
    @State private var hasStartedSetupLoad = false
#if DEBUG
    @State private var calibrationModel: DebugIdentityCalibrationModel
#endif

    init(
        setupModel: DeviceSetupModel,
        simulationModel: SessionSimulationModel,
        memberMemoryManagementModel: MemberMemoryManagementModel?
    ) {
        _setupModel = State(initialValue: setupModel)
        _simulationModel = StateObject(wrappedValue: simulationModel)
        self.memberMemoryManagementModel = memberMemoryManagementModel
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
                calibrationModel: calibrationModel,
                memberMemoryManagementModel: memberMemoryManagementModel
            )
#else
            ContentView(
                simulationModel: simulationModel,
                memberMemoryManagementModel: memberMemoryManagementModel
            )
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
