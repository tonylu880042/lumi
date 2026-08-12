import LumiApplication
import Observation
import Testing
@testable import LumiPresentation

@Suite("Device setup model")
@MainActor
struct DeviceSetupModelTests {
    private let validToken = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY"
    private let marker = "storage-marker-must-not-escape"

    @Test("first load maps a missing token to setup without displaying a stored value")
    func firstLoadMissingTokenShowsSetup() async throws {
        let store = RecordingDeviceAuthorizationStore()
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))

        #expect(model.state == .loading)
        #expect(model.tokenInput.isEmpty)

        await model.load()

        #expect(model.state == .setup(message: nil))
        #expect(model.tokenInput.isEmpty)
    }

    @Test("first load maps a provisioned token to ready without reading it into the field")
    func firstLoadProvisionedTokenShowsReady() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: validToken))
        let store = RecordingDeviceAuthorizationStore(token: token)
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))

        await model.load()

        #expect(model.state == .ready)
        #expect(model.tokenInput.isEmpty)
    }

    @Test("save transitions through saving, reaches ready, and clears transient input")
    func saveTransitionsAndClearsInput() async throws {
        let store = SuspendingDeviceAuthorizationStore()
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))
        await model.load()
        model.tokenInput = validToken

        let operation = Task { @MainActor in
            await model.save()
        }

        await store.waitForSaveEntry()
        #expect(model.state == .saving)

        await store.releaseSave()
        await operation.value

        #expect(model.state == .ready)
        #expect(model.tokenInput.isEmpty)
        #expect(await store.savedTokens.count == 1)
    }

    @Test("empty and invalid input remain in setup with generic validation")
    func invalidInputRemainsInSetup() async throws {
        let store = RecordingDeviceAuthorizationStore()
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

    @Test("storage failure is generic and leaves input available for a retry")
    func saveStorageFailureIsRetryableAndRedacted() async throws {
        let store = RecordingDeviceAuthorizationStore()
        await store.setSaveFailure(TestStorageFailure(marker: marker))
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))
        await model.load()
        model.tokenInput = validToken

        await model.save()

        #expect(model.state == .failure(message: DeviceSetupModel.retryableFailureMessage))
        #expect(model.tokenInput == validToken)
        #expect(String(describing: model.state).contains(marker) == false)
    }

    @Test("save cancellation is generic, retryable, and clears transient input")
    func saveCancellationIsRetryableAndClearsInput() async throws {
        let store = RecordingDeviceAuthorizationStore()
        await store.setSaveCancellation()
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))
        await model.load()
        model.tokenInput = validToken

        await model.save()

        #expect(model.state == .failure(message: DeviceSetupModel.retryableFailureMessage))
        #expect(model.tokenInput.isEmpty)
    }

    @Test("reset confirmation can be canceled without removing authorization")
    func resetCancellationDoesNotRemoveToken() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: validToken))
        let store = RecordingDeviceAuthorizationStore(token: token)
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))
        await model.load()

        model.requestReset()
        #expect(model.isResetConfirmationPresented)

        model.cancelReset()

        #expect(model.isResetConfirmationPresented == false)
        #expect(model.state == .ready)
        #expect(await store.removeCallCount == 0)
        #expect(await store.storedToken == token)
    }

    @Test("confirmed reset removes only the injected environment store and returns setup")
    func confirmedResetUsesOnlyInjectedStore() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: validToken))
        let injectedStore = RecordingDeviceAuthorizationStore(token: token)
        let untouchedStore = RecordingDeviceAuthorizationStore(token: token)
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: injectedStore))
        await model.load()
        model.requestReset()

        await model.confirmReset()

        #expect(model.isResetConfirmationPresented == false)
        #expect(model.state == .setup(message: nil))
        #expect(model.tokenInput.isEmpty)
        #expect(await injectedStore.removeCallCount == 1)
        #expect(await injectedStore.storedToken == nil)
        #expect(await untouchedStore.removeCallCount == 0)
        #expect(await untouchedStore.storedToken == token)
    }

    @Test("reset cancellation is generic, retryable, dismisses confirmation, and clears input")
    func resetCancellationIsRetryableAndClearsInput() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: validToken))
        let store = RecordingDeviceAuthorizationStore(token: token)
        await store.setRemoveCancellation()
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))
        await model.load()
        model.tokenInput = validToken
        model.requestReset()

        await model.confirmReset()

        #expect(model.state == .failure(message: DeviceSetupModel.retryableFailureMessage))
        #expect(model.isResetConfirmationPresented == false)
        #expect(model.tokenInput.isEmpty)
    }

    @Test("reset storage failure is generic and retryable")
    func resetStorageFailureIsRetryableAndRedacted() async throws {
        let store = RecordingDeviceAuthorizationStore()
        await store.setRemoveFailure(TestStorageFailure(marker: marker))
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))
        // Seed the active environment so reset is available from the ready state.
        let token = try #require(DeviceAuthorizationToken(rawValue: validToken))
        await store.setStoredToken(token)
        await model.load()
        model.requestReset()

        await model.confirmReset()

        #expect(model.state == .failure(message: DeviceSetupModel.retryableFailureMessage))
        #expect(model.isResetConfirmationPresented == false)
        #expect(String(describing: model.state).contains(marker) == false)
    }

    @Test("authorization invalidation routes to setup with the exact approved copy")
    func authorizationInvalidationShowsApprovedCopy() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: validToken))
        let store = RecordingDeviceAuthorizationStore(token: token)
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))
        await model.load()
        model.tokenInput = validToken
        model.requestReset()

        model.authorizationInvalidated()

        #expect(model.state == .setup(message: DeviceSetupModel.authorizationInvalidMessage))
        #expect(model.tokenInput.isEmpty)
        #expect(model.isResetConfirmationPresented == false)
    }

    @Test("begin reconfiguration clears invalid setup state without touching authorization storage")
    func beginReconfigurationClearsTransientStateWithoutStoreCalls() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: validToken))
        let store = RecordingDeviceAuthorizationStore(token: token)
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))
        await model.load()

        model.authorizationInvalidated()
        model.tokenInput = validToken
        model.requestReset()

        let loadCallsBefore = await store.loadCallCount
        let saveCallsBefore = await store.saveCallCount
        let removeCallsBefore = await store.removeCallCount
        #expect(model.state == .setup(message: DeviceSetupModel.authorizationInvalidMessage))
        #expect(model.isResetConfirmationPresented)

        let stateObserver = ObservationRecorder()
        withObservationTracking {
            _ = model.state
        } onChange: {
            stateObserver.record()
        }
        let inputObserver = ObservationRecorder()
        withObservationTracking {
            _ = model.tokenInput
        } onChange: {
            inputObserver.record()
        }
        let resetObserver = ObservationRecorder()
        withObservationTracking {
            _ = model.isResetConfirmationPresented
        } onChange: {
            resetObserver.record()
        }

        model.beginReconfiguration()

        #expect(model.state == .setup(message: nil))
        #expect(model.tokenInput.isEmpty)
        #expect(model.isResetConfirmationPresented == false)
        #expect(await store.loadCallCount == loadCallsBefore)
        #expect(await store.saveCallCount == saveCallsBefore)
        #expect(await store.removeCallCount == removeCallsBefore)
        #expect(stateObserver.count == 1)
        #expect(inputObserver.count == 1)
        #expect(resetObserver.count == 1)
    }

    @Test("begin reconfiguration is a no-op outside authorization-invalid setup")
    func beginReconfigurationOutsideInvalidSetupIsNoOp() async throws {
        let store = RecordingDeviceAuthorizationStore()
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))

        model.beginReconfiguration()

        #expect(model.state == .loading)
        #expect(model.tokenInput.isEmpty)
        #expect(model.isResetConfirmationPresented == false)
        #expect(await store.loadCallCount == 0)
        #expect(await store.saveCallCount == 0)
        #expect(await store.removeCallCount == 0)
    }

    @Test("state, input, and reset confirmation are observable Presentation properties")
    func observablePropertiesNotifyChanges() async throws {
        let token = try #require(DeviceAuthorizationToken(rawValue: validToken))
        let store = RecordingDeviceAuthorizationStore(token: token)
        let model = DeviceSetupModel(controller: DeviceAuthorizationController(store: store))
        await model.load()

        let stateObserver = ObservationRecorder()
        withObservationTracking {
            _ = model.state
        } onChange: {
            stateObserver.record()
        }
        model.authorizationInvalidated()

        let inputObserver = ObservationRecorder()
        withObservationTracking {
            _ = model.tokenInput
        } onChange: {
            inputObserver.record()
        }
        model.tokenInput = validToken

        model.authorizationInvalidated()
        let resetObserver = ObservationRecorder()
        withObservationTracking {
            _ = model.isResetConfirmationPresented
        } onChange: {
            resetObserver.record()
        }
        model.requestReset()

        #expect(stateObserver.count == 1)
        #expect(inputObserver.count == 1)
        #expect(resetObserver.count == 1)
    }
}

private actor RecordingDeviceAuthorizationStore: DeviceAuthorizationStore {
    private(set) var storedToken: DeviceAuthorizationToken?
    private(set) var loadCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var removeCallCount = 0

    private var saveFailure: TestStorageFailure?
    private var removeFailure: TestStorageFailure?
    private var saveCancellation = false
    private var removeCancellation = false

    init(token: DeviceAuthorizationToken? = nil) {
        storedToken = token
    }

    func load() async throws -> DeviceAuthorizationToken? {
        loadCallCount += 1
        return storedToken
    }

    func save(_ token: DeviceAuthorizationToken) async throws {
        saveCallCount += 1
        if saveCancellation { throw CancellationError() }
        if let saveFailure { throw saveFailure }
        storedToken = token
    }

    func remove() async throws {
        removeCallCount += 1
        if removeCancellation { throw CancellationError() }
        if let removeFailure { throw removeFailure }
        storedToken = nil
    }

    func setSaveFailure(_ failure: TestStorageFailure) {
        saveFailure = failure
    }

    func setSaveCancellation() {
        saveCancellation = true
    }

    func setRemoveFailure(_ failure: TestStorageFailure) {
        removeFailure = failure
    }

    func setRemoveCancellation() {
        removeCancellation = true
    }

    func setStoredToken(_ token: DeviceAuthorizationToken?) {
        storedToken = token
    }
}

private actor SuspendingDeviceAuthorizationStore: DeviceAuthorizationStore {
    private(set) var savedTokens: [DeviceAuthorizationToken] = []
    private let saveEntryStream: AsyncStream<Void>
    private let saveEntryContinuation: AsyncStream<Void>.Continuation
    private let saveReleaseStream: AsyncStream<Void>
    private let saveReleaseContinuation: AsyncStream<Void>.Continuation
    private var savePending = false

    init() {
        let entry = AsyncStream<Void>.makeStream(
            of: Void.self,
            bufferingPolicy: .unbounded
        )
        saveEntryStream = entry.stream
        saveEntryContinuation = entry.continuation

        let release = AsyncStream<Void>.makeStream(
            of: Void.self,
            bufferingPolicy: .unbounded
        )
        saveReleaseStream = release.stream
        saveReleaseContinuation = release.continuation
    }

    func load() async throws -> DeviceAuthorizationToken? {
        nil
    }

    func save(_ token: DeviceAuthorizationToken) async throws {
        savePending = true
        saveEntryContinuation.yield(())
        defer { savePending = false }

        var releaseIterator = saveReleaseStream.makeAsyncIterator()
        guard await releaseIterator.next() != nil else {
            throw CancellationError()
        }
        savedTokens.append(token)
    }

    func remove() async throws {}

    func waitForSaveEntry() async {
        if savePending { return }
        var entryIterator = saveEntryStream.makeAsyncIterator()
        _ = await entryIterator.next()
    }

    func releaseSave() {
        saveReleaseContinuation.yield(())
    }
}

private struct TestStorageFailure: Error, Sendable {
    let marker: String
}

private final class ObservationRecorder: @unchecked Sendable {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
