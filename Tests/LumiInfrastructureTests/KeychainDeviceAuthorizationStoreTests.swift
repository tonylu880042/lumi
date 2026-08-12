import Foundation
@testable import LumiInfrastructure
import LumiApplication
import Testing

@Suite("Keychain device authorization store")
struct KeychainDeviceAuthorizationStoreTests {
    private let previewService = "com.curves.lumi.live.preview"
    private let productionService = "com.curves.lumi.live.production"
    private let tokenRawValue = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY"
    private let tokenMarker = "raw-token-marker-must-not-escape"
    private let serviceMarker = "service-marker-must-not-escape"

    @Test("rejects empty and whitespace-only services")
    func rejectsInvalidServices() {
        #expect(throws: KeychainDeviceAuthorizationStoreError.invalidService) {
            try KeychainDeviceAuthorizationStore(service: "")
        }
        #expect(throws: KeychainDeviceAuthorizationStoreError.invalidService) {
            try KeychainDeviceAuthorizationStore(service: " \n\t ")
        }
    }

    @Test("loads nil when the generic password is not found")
    func loadNotFoundReturnsNil() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        await client.setCopyResult(.init(status: .itemNotFound, data: nil))

        #expect(try await store.load() == nil)
        let summaries = await client.summaries
        #expect(summaries.map(\.intent) == [.copy])
        #expect(summaries[0].returnsData)
    }

    @Test("loads and revalidates a stored UTF-8 token")
    func loadReturnsValidatedToken() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        let expected = DeviceAuthorizationToken(rawValue: tokenRawValue)!
        await client.setCopyResult(.init(status: .success, data: Data(tokenRawValue.utf8)))

        #expect(try await store.load() == expected)
    }

    @Test("rejects malformed stored data without exposing it")
    func loadRejectsMalformedStoredData() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        await client.setCopyResult(.init(status: .success, data: Data([0xff, 0xfe])))

        await #expect(throws: KeychainDeviceAuthorizationStoreError.invalidStoredData) {
            try await store.load()
        }
    }

    @Test("rejects a stored UTF-8 value that is not a valid token")
    func loadRejectsInvalidStoredToken() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        await client.setCopyResult(.init(status: .success, data: Data("not-a-token".utf8)))

        await #expect(throws: KeychainDeviceAuthorizationStoreError.invalidStoredData) {
            try await store.load()
        }
    }

    @Test("maps a non-success load status to a fixed keychain failure")
    func loadMapsStatusFailure() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        await client.setCopyResult(.init(status: .failure, data: nil))

        do {
            _ = try await store.load()
            Issue.record("Expected keychain failure")
        } catch let error as KeychainDeviceAuthorizationStoreError {
            #expect(error == .keychainFailure)
            assertRedacted(error, markers: [tokenMarker, serviceMarker])
        }
    }

    @Test("adds a generic password with the approved intent")
    func saveUsesApprovedGenericPasswordIntent() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)

        try await store.save(DeviceAuthorizationToken(rawValue: tokenRawValue)!)

        let summaries = await client.summaries
        #expect(summaries.count == 1)
        #expect(summaries[0].intent == .add)
        #expect(summaries[0].service == previewService)
        #expect(summaries[0].account == KeychainDeviceAuthorizationStore.account)
        #expect(summaries[0].dataByteCount == tokenRawValue.utf8.count)
        #expect(summaries[0].accessibility == .whenUnlockedThisDeviceOnly)
        #expect(summaries[0].synchronizable == false)
        #expect(summaries[0].accessGroupIncluded == false)
        #expect(String(describing: summaries[0]).contains(tokenMarker) == false)
    }

    @Test("updates after duplicate add and preserves the same item query")
    func saveUpsertsDuplicateItem() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        await client.setAddStatus(.duplicateItem)
        await client.setUpdateStatus(.success)

        try await store.save(DeviceAuthorizationToken(rawValue: tokenRawValue)!)

        let summaries = await client.summaries
        #expect(summaries.map(\.intent) == [.add, .update])
        #expect(summaries.allSatisfy { $0.service == previewService })
        #expect(summaries.allSatisfy { $0.account == KeychainDeviceAuthorizationStore.account })
        #expect(summaries.allSatisfy { $0.dataByteCount == tokenRawValue.utf8.count })
    }

    @Test("maps update not-found after duplicate add to a fixed failure")
    func saveMapsUpdateNotFound() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        await client.setAddStatus(.duplicateItem)
        await client.setUpdateStatus(.itemNotFound)

        await #expect(throws: KeychainDeviceAuthorizationStoreError.keychainFailure) {
            try await store.save(DeviceAuthorizationToken(rawValue: tokenRawValue)!)
        }
    }

    @Test("maps a generic update failure after duplicate add to a fixed failure")
    func saveMapsGenericUpdateFailure() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        await client.setAddStatus(.duplicateItem)
        await client.setUpdateStatus(.failure)

        await #expect(throws: KeychainDeviceAuthorizationStoreError.keychainFailure) {
            try await store.save(DeviceAuthorizationToken(rawValue: tokenRawValue)!)
        }
    }

    @Test("maps a non-duplicate add failure to a fixed keychain failure")
    func saveMapsAddFailure() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        await client.setAddStatus(.failure)

        await #expect(throws: KeychainDeviceAuthorizationStoreError.keychainFailure) {
            try await store.save(DeviceAuthorizationToken(rawValue: tokenRawValue)!)
        }
    }

    @Test("preview and production service fixtures remain isolated")
    func servicesRemainIsolated() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let preview = try makeStore(service: previewService, client: client)
        let production = try makeStore(service: productionService, client: client)
        let token = DeviceAuthorizationToken(rawValue: tokenRawValue)!

        try await preview.save(token)
        try await production.save(token)

        let services = await client.summaries.map(\.service)
        #expect(services == [previewService, productionService])
    }

    @Test("remove treats not-found as an idempotent success")
    func removeNotFoundIsSuccess() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        await client.setDeleteStatus(.itemNotFound)

        try await store.remove()

        let summaries = await client.summaries
        #expect(summaries.map(\.intent) == [.delete])
        #expect(summaries[0].returnsData == false)
    }

    @Test("maps a non-success remove status to a fixed keychain failure")
    func removeMapsFailure() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        await client.setDeleteStatus(.failure)

        await #expect(throws: KeychainDeviceAuthorizationStoreError.keychainFailure) {
            try await store.remove()
        }
    }

    @Test("preserves client cancellation on load")
    func loadPreservesCancellation() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        await client.setCopyCancellation()

        await #expect(throws: CancellationError.self) {
            try await store.load()
        }
    }

    @Test("a canceled save does not call the client")
    func canceledSaveHasNoSideEffect() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        let operation = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            try await store.save(DeviceAuthorizationToken(rawValue: tokenRawValue)!)
        }

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(await client.summaries.isEmpty)
    }

    @Test("a canceled reset does not call the client")
    func canceledRemoveHasNoSideEffect() async throws {
        let client = RecordingKeychainDeviceAuthorizationClient()
        let store = try makeStore(service: previewService, client: client)
        let operation = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            try await store.remove()
        }

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(await client.summaries.isEmpty)
    }

    @Test("store errors have fixed redacted diagnostics")
    func storeErrorsAreRedacted() {
        for error in [
            KeychainDeviceAuthorizationStoreError.invalidService,
            KeychainDeviceAuthorizationStoreError.invalidStoredData,
            KeychainDeviceAuthorizationStoreError.keychainFailure,
        ] {
            assertRedacted(error, markers: [tokenMarker, serviceMarker])
        }
    }
}

private func makeStore(
    service: String,
    client: RecordingKeychainDeviceAuthorizationClient
) throws -> KeychainDeviceAuthorizationStore {
    try KeychainDeviceAuthorizationStore(service: service, client: client)
}

private actor RecordingKeychainDeviceAuthorizationClient:
    KeychainDeviceAuthorizationStoreClient
{
    private(set) var summaries: [KeychainRequestSummary] = []
    private var addStatus: KeychainOperationStatus = .success
    private var copyResult = KeychainCopyResult(status: .itemNotFound, data: nil)
    private var updateStatus: KeychainOperationStatus = .success
    private var deleteStatus: KeychainOperationStatus = .success
    private var copyCancellation = false

    func add(_ request: KeychainRequest) async throws -> KeychainOperationStatus {
        summaries.append(request.summary)
        return addStatus
    }

    func copy(_ request: KeychainRequest) async throws -> KeychainCopyResult {
        summaries.append(request.summary)
        if copyCancellation { throw CancellationError() }
        return copyResult
    }

    func update(_ request: KeychainRequest) async throws -> KeychainOperationStatus {
        summaries.append(request.summary)
        return updateStatus
    }

    func delete(_ request: KeychainRequest) async throws -> KeychainOperationStatus {
        summaries.append(request.summary)
        return deleteStatus
    }

    func setAddStatus(_ status: KeychainOperationStatus) {
        addStatus = status
    }

    func setCopyResult(_ result: KeychainCopyResult) {
        copyResult = result
    }

    func setCopyCancellation() {
        copyCancellation = true
    }

    func setUpdateStatus(_ status: KeychainOperationStatus) {
        updateStatus = status
    }

    func setDeleteStatus(_ status: KeychainOperationStatus) {
        deleteStatus = status
    }
}

private func assertRedacted(
    _ error: KeychainDeviceAuthorizationStoreError,
    markers: [String]
) {
    let description = String(describing: error)
    let debugDescription = String(reflecting: error)
    let mirror = Mirror(reflecting: error)

    for marker in markers {
        #expect(!description.contains(marker))
        #expect(!debugDescription.contains(marker))
        #expect(!String(describing: mirror).contains(marker))
    }
    #expect(mirror.children.isEmpty)
}
