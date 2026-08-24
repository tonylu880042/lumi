import LumiApplication
import LumiPresentation
import SwiftUI
import Testing
@testable import LumiApp

@MainActor
@Suite("App setup routing")
struct AppRootRoutingTests {
    private let validToken = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY"
    private let marker = "token-marker-must-not-escape"

    @Test("pure routing distinguishes every setup lifecycle destination")
    func routingDistinguishesEveryDestination() {
        #expect(AppRootRouting.destination(for: .loading) == .loading)
        #expect(AppRootRouting.destination(for: .setup(message: nil)) == .setup(message: nil))
        #expect(
            AppRootRouting.destination(for: .setup(message: DeviceSetupModel.authorizationInvalidMessage))
                == .setup(message: DeviceSetupModel.authorizationInvalidMessage)
        )
        #expect(AppRootRouting.destination(for: .saving) == .saving)
        #expect(AppRootRouting.destination(for: .ready) == .ready)
        #expect(
            AppRootRouting.destination(for: .failure(message: DeviceSetupModel.retryableFailureMessage))
                == .failure(message: DeviceSetupModel.retryableFailureMessage)
        )
    }

    @Test("missing authorization routes setup without displaying stored token")
    func missingAuthorizationRoutesSetup() async {
        let store = RecordingAuthorizationStore()
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))

        await model.load()

        #expect(model.state == .setup(message: nil))
        #expect(AppRootRouting.destination(for: model.state) == .setup(message: nil))
        #expect(model.tokenInput.isEmpty)
    }

    @Test("provisioned authorization routes the injected existing content")
    func provisionedAuthorizationRoutesReadyContent() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: validToken))
        let model = DeviceSetupModel(
            controller: DeviceAuthorizationController(
                store: RecordingAuthorizationStore(token: token)
            )
        )

        await model.load()
        _ = AppRootView(setupModel: model) { markerView }

        #expect(AppRootRouting.destination(for: model.state) == .ready)
    }

    @Test("authorization invalidation preserves exact copy and reconfiguration clears only transient state")
    func authorizationInvalidationOffersReconfiguration() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: validToken))
        let store = RecordingAuthorizationStore(token: token)
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))

        await model.load()
        model.tokenInput = validToken
        model.authorizationInvalidated()

        #expect(
            AppRootRouting.destination(for: model.state)
                == .setup(message: DeviceSetupModel.authorizationInvalidMessage)
        )
        #expect(DeviceSetupView.viewIntent.reconfigureLabel == "重新設定")
        #expect(model.tokenInput.isEmpty)

        let removeCallsBefore = await store.removeCallCount
        model.beginReconfiguration()

        #expect(model.state == .setup(message: nil))
        #expect(await store.removeCallCount == removeCallsBefore)
    }

    @Test("empty and invalid values retain setup with exact validation copy")
    func invalidInputDoesNotSave() async {
        let store = RecordingAuthorizationStore()
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))
        await model.load()

        await model.save()
        #expect(model.state == .setup(message: DeviceSetupModel.invalidInputMessage))
        #expect(await store.saveCallCount == 0)

        model.tokenInput = "not-a-valid-device-token"
        await model.save()

        #expect(model.state == .setup(message: DeviceSetupModel.invalidInputMessage))
        #expect(await store.saveCallCount == 0)
    }

    @Test("successful save reaches ready and clears transient input")
    func successfulSaveReachesReady() async {
        let store = RecordingAuthorizationStore()
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))
        await model.load()
        model.tokenInput = validToken

        await model.save()

        #expect(model.state == .ready)
        #expect(AppRootRouting.destination(for: model.state) == .ready)
        #expect(model.tokenInput.isEmpty)
        #expect(await store.saveCallCount == 1)
    }

    @Test("reset cancellation does not delete current authorization")
    func resetCancellationDoesNotDeleteAuthorization() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: validToken))
        let store = RecordingAuthorizationStore(token: token)
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))
        await model.load()

        model.requestReset()
        #expect(model.isResetConfirmationPresented)
        model.cancelReset()

        #expect(model.state == .ready)
        #expect(await store.removeCallCount == 0)
        #expect(await store.storedToken == token)
    }

    @Test("confirmed reset uses only current namespace and returns setup")
    func confirmedResetUsesCurrentNamespace() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: validToken))
        let activeStore = RecordingAuthorizationStore(token: token)
        let untouchedStore = RecordingAuthorizationStore(token: token)
        let model = DeviceSetupModel(
            controller: DeviceAuthorizationController(store: activeStore)
        )
        await model.load()

        model.requestReset()
        await model.confirmReset()

        #expect(model.state == .setup(message: nil))
        #expect(AppRootRouting.destination(for: model.state) == .setup(message: nil))
        #expect(await activeStore.removeCallCount == 1)
        #expect(await activeStore.storedToken == nil)
        #expect(await untouchedStore.removeCallCount == 0)
        #expect(await untouchedStore.storedToken == token)
    }

    @Test("retryable failure remains failure and does not trigger reset")
    func retryableFailureDoesNotResetAuthorization() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: validToken))
        let store = RecordingAuthorizationStore(token: token)
        await store.setSaveFailure(StorageFailure())
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))
        await model.load()
        model.tokenInput = validToken

        await model.save()

        #expect(model.state == .failure(message: DeviceSetupModel.retryableFailureMessage))
        #expect(AppRootRouting.destination(for: model.state) == .failure(message: DeviceSetupModel.retryableFailureMessage))
        #expect(await store.removeCallCount == 0)
        #expect(await store.storedToken == token)
    }

    @Test("setup view intent uses one-tap paste and exposes no token")
    func setupViewIntentUsesOneTapPaste() {
        let intent = DeviceSetupView.viewIntent
        let accessibilityText = intent.accessibilityLabels.joined(separator: " ")

        #expect(intent.instructions == "先複製此裝置的授權值，再按下「貼上」啟用語音。")
        #expect(intent.pasteButtonAccessibilityLabel == "從剪貼簿啟用語音")
        #expect(intent.includesQRCodeAffordance == false)
        #expect(accessibilityText.contains(validToken) == false)
        #expect(accessibilityText.contains(marker) == false)
        #expect(accessibilityText.localizedCaseInsensitiveContains("qr") == false)
    }

    @Test("ready screen keeps device reset and session controls in separate corners")
    func readyScreenSeparatesTopControls() throws {
        #expect(AppOverlayLayout.deviceSetupControl == .topLeading)
        #expect(AppOverlayLayout.sessionControls == .topTrailing)
        #expect(
            AppOverlayLayout.deviceSetupControl
                != AppOverlayLayout.sessionControls
        )

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LumiApp/Sources/AppRootView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("Image(systemName: \"gearshape\")"))
        #expect(
            source.contains("Button(DeviceSetupView.viewIntent.resetLabel)")
                == false
        )
    }

    private var markerView: some View {
        Text(marker)
    }
}

private actor RecordingAuthorizationStore: DeviceAuthorizationStore {
    private(set) var storedToken: DeviceAuthorizationToken?
    private(set) var loadCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var removeCallCount = 0
    private var saveFailure: StorageFailure?

    init(token: DeviceAuthorizationToken? = nil) {
        storedToken = token
    }

    func load() async throws -> DeviceAuthorizationToken? {
        loadCallCount += 1
        return storedToken
    }

    func save(_ token: DeviceAuthorizationToken) async throws {
        saveCallCount += 1
        if let saveFailure {
            throw saveFailure
        }
        storedToken = token
    }

    func remove() async throws {
        removeCallCount += 1
        storedToken = nil
    }

    func setSaveFailure(_ failure: StorageFailure) {
        saveFailure = failure
    }
}

private struct StorageFailure: Error, Sendable {}
