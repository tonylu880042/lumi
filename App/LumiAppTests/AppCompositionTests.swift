import Foundation
import Testing
@testable import LumiApp
import LumiApplication
import LumiInfrastructure
import LumiPresentation

@Suite("App runtime composition")
struct AppCompositionTests {
    private let previewEndpoint = "https://preview-broker.example.test/api/realtime/client-secret"

    @Test("Invalid Live composition is unavailable before the builder runs")
    @MainActor
    func invalidLiveCompositionDoesNotInvokeBuilder() throws {
        let plan = AppRuntimeConfiguration.compositionPlan(
            isLive: true,
            brokerEndpoint: nil,
            brokerEnvironment: "preview"
        )
        #expect(
            plan == .unavailable(
                message: AppRuntimeConfiguration.liveUnavailableMessage
            )
        )

        let recorder = CompositionBuilderRecorder()
        let destination = AppCompositionFactory(builder: recorder.build).make(plan: plan)

        guard case let .unavailable(message) = destination else {
            Issue.record("Invalid Live plan must produce unavailable destination")
            return
        }
        #expect(message == AppRuntimeConfiguration.liveUnavailableMessage)
        #expect(recorder.buildCallCount == 0)
    }

    @Test("Live plan maps each broker environment to its isolated Keychain service")
    func livePlanMapsEnvironmentToKeychainNamespace() throws {
        let preview = AppRuntimeConfiguration.compositionPlan(
            isLive: true,
            brokerEndpoint: previewEndpoint,
            brokerEnvironment: "preview"
        )
        let production = AppRuntimeConfiguration.compositionPlan(
            isLive: true,
            brokerEndpoint: "https://production-broker.example.test/api/realtime/client-secret",
            brokerEnvironment: "production"
        )

        #expect(
            preview == .live(
                environment: .preview,
                brokerEndpoint: URL(string: previewEndpoint)!
            )
        )
        #expect(
            production == .live(
                environment: .production,
                brokerEndpoint: URL(string: "https://production-broker.example.test/api/realtime/client-secret")!
            )
        )
        #expect(
            AppRuntimeConfiguration.keychainService(for: .preview)
                == "com.curves.lumi.live.preview"
        )
        #expect(
            AppRuntimeConfiguration.keychainService(for: .production)
                == "com.curves.lumi.live.production"
        )
    }

    @Test("Mock composition does not construct authorization or provider voice")
    @MainActor
    func mockCompositionUsesOfflineVoicePlan() throws {
        let plan = AppRuntimeConfiguration.compositionPlan(
            isLive: false,
            brokerEndpoint: nil,
            brokerEnvironment: nil
        )
        #expect(plan == .mock)

        let recorder = CompositionBuilderRecorder()
        let destination = AppCompositionFactory(builder: recorder.build).make(plan: plan)

        #expect(recorder.buildCallCount == 1)
        guard case .mock(let simulationModel) = destination else {
            Issue.record("Mock plan must produce the direct Mock destination")
            return
        }
        #expect(simulationModel.hasArtificialVoiceControls)
    }

    @Test("Valid Live composition remains a concrete Live plan without Mock fallback")
    @MainActor
    func validLiveCompositionUsesLiveBuilderPlan() throws {
        let plan = AppRuntimeConfiguration.compositionPlan(
            isLive: true,
            brokerEndpoint: previewEndpoint,
            brokerEnvironment: "preview"
        )
        let recorder = CompositionBuilderRecorder()
        let destination = AppCompositionFactory(builder: recorder.build).make(plan: plan)

        #expect(recorder.buildCallCount == 1)
        #expect(recorder.lastPlan == plan)
        guard case .live = destination else {
            Issue.record("Valid Live plan must not fall back to Mock")
            return
        }
    }

    @Test("Production Live composition uses real voice capabilities and fresh roots")
    @MainActor
    func productionLiveCompositionUsesRealVoiceAndFreshRoots() throws {
        let plan = AppRuntimeConfiguration.compositionPlan(
            isLive: true,
            brokerEndpoint: previewEndpoint,
            brokerEnvironment: "preview"
        )

        let first = AppCompositionFactory().make(plan: plan)
        let second = AppCompositionFactory().make(plan: plan)

        guard case let .live(firstSetup, firstSimulation) = first,
              case let .live(secondSetup, secondSimulation) = second
        else {
            Issue.record("Production Live plan must build the Live destination")
            return
        }

        #expect(!firstSimulation.hasArtificialVoiceControls)
        #expect(!secondSimulation.hasArtificialVoiceControls)
        #expect(firstSetup !== secondSetup)
        #expect(firstSimulation !== secondSimulation)
        #expect(firstSetup.state == .loading)
        #expect(secondSetup.state == .loading)
    }

    @Test("Unavailable copy is exact and renders an independent destination")
    @MainActor
    func unavailableCopyIsExact() {
        #expect(AppRuntimeConfiguration.liveUnavailableMessage == "語音服務尚未完成設定，請聯絡管理員。")

        let view = AppCompositionUnavailableView(
            message: AppRuntimeConfiguration.liveUnavailableMessage
        )
        _ = view.body
    }

    @Test("Production Mock composition stays offline and creates fresh models")
    @MainActor
    func productionMockCompositionStaysOffline() {
        let first = AppCompositionFactory().make(plan: .mock)
        let second = AppCompositionFactory().make(plan: .mock)

        guard case let .mock(firstModel) = first,
              case let .mock(secondModel) = second
        else {
            Issue.record("Mock plan must build the direct Mock destination")
            return
        }

        #expect(firstModel.hasArtificialVoiceControls)
        #expect(secondModel.hasArtificialVoiceControls)
        #expect(firstModel !== secondModel)
    }

    @Test("Compiled descriptor follows the selected build mode")
    func compiledDescriptorFollowsBuildMode() throws {
        #if LUMI_LIVE
        #expect(throws: AppRuntimeConfigurationError.missingBrokerEndpoint) {
            try AppRuntimeConfiguration.descriptor()
        }
        #else
        #expect(try AppRuntimeConfiguration.descriptor() == .mock)
        #endif
    }

    @Test("Compiled composition plan follows the selected build mode")
    func compiledCompositionPlanFollowsBuildMode() {
        #if LUMI_LIVE
        #expect(
            AppRuntimeConfiguration.compositionPlan()
                == .unavailable(message: AppRuntimeConfiguration.liveUnavailableMessage)
        )
        #else
        #expect(AppRuntimeConfiguration.compositionPlan() == .mock)
        #endif
    }

    @Test("Mock descriptor is selected without Live configuration")
    func mockDescriptorDoesNotNeedLiveConfiguration() throws {
        let descriptor = try AppRuntimeConfiguration.descriptor(
            isLive: false,
            brokerEndpoint: nil,
            brokerEnvironment: nil
        )

        #expect(descriptor == .mock)
    }

    @Test("Live descriptor selects the Preview broker")
    func liveDescriptorSelectsPreview() throws {
        let descriptor = try AppRuntimeConfiguration.descriptor(
            isLive: true,
            brokerEndpoint: previewEndpoint,
            brokerEnvironment: "preview"
        )

        #expect(
            descriptor == .live(
                environment: .preview,
                brokerEndpoint: URL(string: previewEndpoint)!
            )
        )
    }

    @Test("Live descriptor fails with a typed missing endpoint")
    func liveDescriptorRejectsMissingEndpoint() {
        #expect(throws: AppRuntimeConfigurationError.missingBrokerEndpoint) {
            try AppRuntimeConfiguration.descriptor(
                isLive: true,
                brokerEndpoint: nil,
                brokerEnvironment: "preview"
            )
        }
    }

    @Test("Empty or whitespace-only Live endpoint is missing")
    func liveDescriptorRejectsEmptyEndpointAsMissing() {
        #expect(throws: AppRuntimeConfigurationError.missingBrokerEndpoint) {
            try AppRuntimeConfiguration.descriptor(
                isLive: true,
                brokerEndpoint: " \n\t",
                brokerEnvironment: "preview"
            )
        }
    }

    @Test("Live descriptor rejects a non-HTTPS endpoint")
    func liveDescriptorRejectsHTTP() {
        #expect(throws: AppRuntimeConfigurationError.malformedBrokerEndpoint) {
            try AppRuntimeConfiguration.descriptor(
                isLive: true,
                brokerEndpoint: "http://broker.example.test/client-secret",
                brokerEnvironment: "preview"
            )
        }
    }

    @Test("Live descriptor rejects an endpoint with credentials")
    func liveDescriptorRejectsCredentials() {
        #expect(throws: AppRuntimeConfigurationError.malformedBrokerEndpoint) {
            try AppRuntimeConfiguration.descriptor(
                isLive: true,
                brokerEndpoint: "https://user:password@broker.example.test/client-secret",
                brokerEnvironment: "preview"
            )
        }
    }

    @Test("Live descriptor rejects an endpoint with a query or fragment")
    func liveDescriptorRejectsQueryAndFragment() {
        #expect(throws: AppRuntimeConfigurationError.malformedBrokerEndpoint) {
            try AppRuntimeConfiguration.descriptor(
                isLive: true,
                brokerEndpoint: "https://broker.example.test/client-secret?mode=preview",
                brokerEnvironment: "preview"
            )
        }

        #expect(throws: AppRuntimeConfigurationError.malformedBrokerEndpoint) {
            try AppRuntimeConfiguration.descriptor(
                isLive: true,
                brokerEndpoint: "https://broker.example.test/client-secret#preview",
                brokerEnvironment: "preview"
            )
        }
    }

    @Test("Live descriptor rejects a relative endpoint")
    func liveDescriptorRejectsRelativeEndpoint() {
        #expect(throws: AppRuntimeConfigurationError.malformedBrokerEndpoint) {
            try AppRuntimeConfiguration.descriptor(
                isLive: true,
                brokerEndpoint: "/api/realtime/client-secret",
                brokerEnvironment: "preview"
            )
        }
    }

    @Test("Live descriptor reports missing environment")
    func liveDescriptorRejectsMissingEnvironment() {
        #expect(throws: AppRuntimeConfigurationError.missingBrokerEnvironment) {
            try AppRuntimeConfiguration.descriptor(
                isLive: true,
                brokerEndpoint: previewEndpoint,
                brokerEnvironment: nil
            )
        }
    }

    @Test("Live descriptor rejects an unsupported environment")
    func liveDescriptorRejectsMalformedEnvironment() {
        #expect(throws: AppRuntimeConfigurationError.malformedBrokerEnvironment) {
            try AppRuntimeConfiguration.descriptor(
                isLive: true,
                brokerEndpoint: previewEndpoint,
                brokerEnvironment: "staging"
            )
        }
    }
}

@MainActor
private final class CompositionBuilderRecorder {
    private(set) var buildCallCount = 0
    private(set) var lastPlan: AppCompositionPlan?

    func build(_ plan: AppCompositionPlan) -> AppCompositionDestination {
        buildCallCount += 1
        lastPlan = plan

        switch plan {
        case .mock:
            let hardware = MockHardwareControlPort()
            let identity = MockIdentityRecognitionAdapter()
            let voice = MockVoiceSessionPort()
            let coordinator = AssistantSessionCoordinator(
                hardware: hardware,
                identity: identity,
                voice: voice
            )
            return .mock(
                simulationModel:
                SessionSimulationModel(
                    coordinator: coordinator,
                    hardware: hardware,
                    identity: identity,
                    voiceSimulationControls: VoiceSimulationControls(voice: voice)
                )
            )
        case .live:
            let hardware = MockHardwareControlPort()
            let identity = MockIdentityRecognitionAdapter()
            let voice = MockVoiceSessionPort()
            let coordinator = AssistantSessionCoordinator(
                hardware: hardware,
                identity: identity,
                voice: voice
            )
            let setupModel = DeviceSetupModel(
                controller: DeviceAuthorizationController(store: InMemoryDeviceAuthorizationStore())
            )
            return .live(
                setupModel: setupModel,
                simulationModel: SessionSimulationModel(
                    coordinator: coordinator,
                    hardware: hardware,
                    identity: identity
                )
            )
        case let .unavailable(message):
            return .unavailable(message: message)
        }
    }
}

private struct InMemoryDeviceAuthorizationStore: DeviceAuthorizationStore {
    func load() async throws -> DeviceAuthorizationToken? { nil }
    func save(_: DeviceAuthorizationToken) async throws {}
    func remove() async throws {}
}
