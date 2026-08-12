import LumiApplication
import Testing

@Suite("Device authorization controller")
struct DeviceAuthorizationControllerTests {
    private let validRawValue = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY"
    private let marker = "storage-marker-must-not-escape"

    @Test("reports missing when the store has no token")
    func reportsMissingAuthorization() async throws {
        let store = RecordingDeviceAuthorizationStore()
        let controller = DeviceAuthorizationController(store: store)

        #expect(try await controller.authorizationStatus() == .missing)
    }

    @Test("reports provisioned when the store contains a token")
    func reportsProvisionedAuthorization() async throws {
        let token = DeviceAuthorizationToken(rawValue: validRawValue)!
        let store = RecordingDeviceAuthorizationStore(token: token)
        let controller = DeviceAuthorizationController(store: store)

        #expect(try await controller.authorizationStatus() == .provisioned)
    }

    @Test("rejects an invalid token without writing to the store")
    func invalidTokenDoesNotWrite() async throws {
        let store = RecordingDeviceAuthorizationStore()
        let controller = DeviceAuthorizationController(store: store)

        do {
            try await controller.save(rawValue: "invalid-token")
            Issue.record("Expected invalid token to be rejected")
        } catch let error as DeviceAuthorizationControllerError {
            #expect(error == .invalidToken)
        }

        #expect(await store.saveCallCount == 0)
        #expect(await store.savedTokens.isEmpty)
    }

    @Test("saves the exact validated token")
    func savesExactToken() async throws {
        let store = RecordingDeviceAuthorizationStore()
        let controller = DeviceAuthorizationController(store: store)
        let expected = DeviceAuthorizationToken(rawValue: validRawValue)!

        try await controller.save(rawValue: validRawValue)

        #expect(await store.savedTokens == [expected])
    }

    @Test("reset removes only the injected store token")
    func resetUsesOnlyInjectedStore() async throws {
        let token = DeviceAuthorizationToken(rawValue: validRawValue)!
        let injectedStore = RecordingDeviceAuthorizationStore(token: token)
        let untouchedStore = RecordingDeviceAuthorizationStore(token: token)
        let controller = DeviceAuthorizationController(store: injectedStore)

        try await controller.reset()

        #expect(await injectedStore.removeCallCount == 1)
        #expect(await untouchedStore.removeCallCount == 0)
        #expect(await untouchedStore.storedToken == token)
    }

    @Test("maps load failures to a fixed privacy-safe application error")
    func mapsLoadFailure() async throws {
        let store = RecordingDeviceAuthorizationStore()
        await store.setLoadFailure(TestStorageFailure(marker: marker))
        let controller = DeviceAuthorizationController(store: store)

        do {
            _ = try await controller.authorizationStatus()
            Issue.record("Expected load failure to be mapped")
        } catch let error as DeviceAuthorizationControllerError {
            #expect(error == .storageFailure)
            assertRedacted(error, marker: marker)
        }
    }

    @Test("maps save failures to a fixed privacy-safe application error")
    func mapsSaveFailure() async throws {
        let store = RecordingDeviceAuthorizationStore()
        await store.setSaveFailure(TestStorageFailure(marker: marker))
        let controller = DeviceAuthorizationController(store: store)

        do {
            try await controller.save(rawValue: validRawValue)
            Issue.record("Expected save failure to be mapped")
        } catch let error as DeviceAuthorizationControllerError {
            #expect(error == .storageFailure)
            assertRedacted(error, marker: marker)
        }
    }

    @Test("maps reset failures to a fixed privacy-safe application error")
    func mapsResetFailure() async throws {
        let store = RecordingDeviceAuthorizationStore()
        await store.setRemoveFailure(TestStorageFailure(marker: marker))
        let controller = DeviceAuthorizationController(store: store)

        do {
            try await controller.reset()
            Issue.record("Expected reset failure to be mapped")
        } catch let error as DeviceAuthorizationControllerError {
            #expect(error == .storageFailure)
            assertRedacted(error, marker: marker)
        }
    }

    @Test("propagates cancellation from a store operation")
    func propagatesStoreCancellation() async throws {
        let store = RecordingDeviceAuthorizationStore()
        await store.setSaveCancellation()
        let controller = DeviceAuthorizationController(store: store)

        await #expect(throws: CancellationError.self) {
            try await controller.save(rawValue: validRawValue)
        }
        #expect(await store.saveCallCount == 1)
    }

    @Test("cancellation before save has no later save side effect")
    func canceledSaveDoesNotCallStore() async throws {
        let store = RecordingDeviceAuthorizationStore()
        let controller = DeviceAuthorizationController(store: store)
        let operation = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            try await controller.save(rawValue: validRawValue)
        }

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }

        #expect(await store.saveCallCount == 0)
    }

    @Test("cancellation before reset has no later remove side effect")
    func canceledResetDoesNotCallStore() async throws {
        let store = RecordingDeviceAuthorizationStore()
        let controller = DeviceAuthorizationController(store: store)
        let operation = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            try await controller.reset()
        }

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }

        #expect(await store.removeCallCount == 0)
    }

    @Test("caller cancellation wins when a started store operation fails")
    func cancellationWinsOverStartedStoreFailure() async throws {
        let store = SuspendingDeviceAuthorizationStore()
        let controller = DeviceAuthorizationController(store: store)
        let operation = Task {
            try await controller.save(rawValue: validRawValue)
        }

        #expect(await waitFor { await store.hasPendingSave })
        operation.cancel()
        await store.releaseSave(with: TestStorageFailure(marker: marker))

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(await store.savedTokens.isEmpty)
    }

    @Test("controller errors have fixed redacted diagnostics")
    func controllerErrorsAreRedacted() {
        for error in [
            DeviceAuthorizationControllerError.invalidToken,
            DeviceAuthorizationControllerError.storageFailure,
        ] {
            assertRedacted(error, marker: marker)
        }
    }
}

private actor RecordingDeviceAuthorizationStore: DeviceAuthorizationStore {
    private(set) var storedToken: DeviceAuthorizationToken?
    private(set) var savedTokens: [DeviceAuthorizationToken] = []
    private(set) var saveCallCount = 0
    private(set) var removeCallCount = 0

    private var loadFailure: TestStorageFailure?
    private var saveFailure: TestStorageFailure?
    private var removeFailure: TestStorageFailure?
    private var saveCancellation = false

    init(token: DeviceAuthorizationToken? = nil) {
        storedToken = token
    }

    func load() async throws -> DeviceAuthorizationToken? {
        if let loadFailure { throw loadFailure }
        return storedToken
    }

    func save(_ token: DeviceAuthorizationToken) async throws {
        saveCallCount += 1
        if saveCancellation { throw CancellationError() }
        if let saveFailure { throw saveFailure }
        storedToken = token
        savedTokens.append(token)
    }

    func remove() async throws {
        removeCallCount += 1
        if let removeFailure { throw removeFailure }
        storedToken = nil
    }

    func setLoadFailure(_ failure: TestStorageFailure) {
        loadFailure = failure
    }

    func setSaveFailure(_ failure: TestStorageFailure) {
        saveFailure = failure
    }

    func setRemoveFailure(_ failure: TestStorageFailure) {
        removeFailure = failure
    }

    func setSaveCancellation() {
        saveCancellation = true
    }
}

private actor SuspendingDeviceAuthorizationStore: DeviceAuthorizationStore {
    private(set) var savedTokens: [DeviceAuthorizationToken] = []
    private var pendingSave: CheckedContinuation<Void, any Error>?

    var hasPendingSave: Bool {
        pendingSave != nil
    }

    func load() async throws -> DeviceAuthorizationToken? {
        nil
    }

    func save(_ token: DeviceAuthorizationToken) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            pendingSave = continuation
        }
        savedTokens.append(token)
    }

    func remove() async throws {}

    func releaseSave(with error: any Error) {
        guard let pendingSave else { return }
        self.pendingSave = nil
        pendingSave.resume(throwing: error)
    }
}

private struct TestStorageFailure: Error, Equatable, Sendable, CustomStringConvertible {
    let marker: String

    var description: String { marker }
}

private func assertRedacted(
    _ error: DeviceAuthorizationControllerError,
    marker: String
) {
    let description = String(describing: error)
    let debugDescription = String(reflecting: error)
    let mirror = Mirror(reflecting: error)

    #expect(!description.contains(marker))
    #expect(!debugDescription.contains(marker))
    #expect(!String(describing: mirror).contains(marker))
    #expect(mirror.children.isEmpty)
}

private func waitFor(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<100 {
        if await condition() {
            return true
        }
        await Task.yield()
    }
    return false
}
