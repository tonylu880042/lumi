import Dispatch
import Foundation
import LumiApplication
#if canImport(Security)
import Security
#endif

/// Fixed failures for the Keychain-backed device authorization store.
public enum KeychainDeviceAuthorizationStoreError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case invalidService
    case invalidStoredData
    case keychainFailure

    public var description: String {
        switch self {
        case .invalidService:
            "Keychain service is invalid."
        case .invalidStoredData:
            "Keychain item data is invalid."
        case .keychainFailure:
            "Keychain operation failed."
        }
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, unlabeledChildren: [], displayStyle: .enum)
    }
}

/// The operation represented by a sanitized Keychain request.
enum KeychainOperation: Equatable, Sendable {
    case add
    case copy
    case update
    case delete
}

/// The only accessibility policy used by this store.
enum KeychainAccessibility: Equatable, Sendable {
    case whenUnlockedThisDeviceOnly
}

/// A non-sensitive projection used by injected test clients.
struct KeychainRequestSummary:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    let intent: KeychainOperation
    let service: String
    let account: String
    let dataByteCount: Int?
    let returnsData: Bool
    let accessibility: KeychainAccessibility
    let synchronizable: Bool
    let accessGroupIncluded: Bool

    var description: String { "<redacted>" }

    var debugDescription: String { "<redacted>" }

    var customMirror: Mirror {
        Mirror(self, unlabeledChildren: [], displayStyle: .struct)
    }
}

/// Sendable request value. Raw Data exists only inside the Infrastructure seam
/// long enough for the system client to build a Security dictionary.
struct KeychainRequest:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    let intent: KeychainOperation
    let service: String
    let account: String
    let data: Data?
    let returnsData: Bool
    let accessibility: KeychainAccessibility
    let synchronizable: Bool
    let accessGroupIncluded: Bool

    var summary: KeychainRequestSummary {
        KeychainRequestSummary(
            intent: intent,
            service: service,
            account: account,
            dataByteCount: data?.count,
            returnsData: returnsData,
            accessibility: accessibility,
            synchronizable: synchronizable,
            accessGroupIncluded: accessGroupIncluded
        )
    }

    var description: String { "<redacted>" }

    var debugDescription: String { "<redacted>" }

    var customMirror: Mirror {
        Mirror(self, unlabeledChildren: [], displayStyle: .struct)
    }
}

/// Result of a Keychain copy operation after the system client has converted
/// its CF result into Sendable Foundation data.
struct KeychainCopyResult: Sendable, CustomReflectable {
    let status: KeychainOperationStatus
    let data: Data?

    init(status: KeychainOperationStatus, data: Data?) {
        self.status = status
        self.data = data
    }

    var customMirror: Mirror {
        Mirror(self, unlabeledChildren: [], displayStyle: .struct)
    }
}

/// Status categories retained across the injected Security seam.
enum KeychainOperationStatus: Equatable, Sendable {
    case success
    case duplicateItem
    case itemNotFound
    case failure
}

/// Injectable async boundary around the blocking Security functions.
protocol KeychainDeviceAuthorizationStoreClient: Sendable {
    func add(_ request: KeychainRequest) async throws -> KeychainOperationStatus
    func copy(_ request: KeychainRequest) async throws -> KeychainCopyResult
    func update(_ request: KeychainRequest) async throws -> KeychainOperationStatus
    func delete(_ request: KeychainRequest) async throws -> KeychainOperationStatus
}

/// Stores one device authorization token in a namespaced generic-password item.
public struct KeychainDeviceAuthorizationStore: DeviceAuthorizationStore, Sendable {
    /// The one fixed, non-sensitive generic-password account.
    static let account = "device-authorization"

    private let service: String
    private let client: any KeychainDeviceAuthorizationStoreClient

    /// Creates a production store backed by the system Keychain client.
    public init(service: String) throws(KeychainDeviceAuthorizationStoreError) {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidService
        }

        self.service = service
        self.client = SystemKeychainDeviceAuthorizationStoreClient()
    }

    /// Creates a store around an injected client for deterministic tests.
    init(
        service: String,
        client: any KeychainDeviceAuthorizationStoreClient
    ) throws(KeychainDeviceAuthorizationStoreError) {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidService
        }

        self.service = service
        self.client = client
    }

    public func load() async throws -> DeviceAuthorizationToken? {
        let request = makeRequest(
            intent: .copy,
            data: nil,
            returnsData: true
        )
        let result = try await performClient {
            try await client.copy(request)
        }

        switch result.status {
        case .itemNotFound:
            return nil
        case .success:
            guard
                let data = result.data,
                let rawValue = String(data: data, encoding: .utf8),
                let token = DeviceAuthorizationToken(rawValue: rawValue)
            else {
                throw KeychainDeviceAuthorizationStoreError.invalidStoredData
            }
            return token
        case .duplicateItem, .failure:
            throw KeychainDeviceAuthorizationStoreError.keychainFailure
        }
    }

    public func save(_ token: DeviceAuthorizationToken) async throws {
        let data = Data(token.rawValue.utf8)
        let addRequest = makeRequest(intent: .add, data: data, returnsData: false)
        let addStatus = try await performClient {
            try await client.add(addRequest)
        }

        switch addStatus {
        case .success:
            return
        case .duplicateItem:
            try Task.checkCancellation()
            let updateRequest = makeRequest(
                intent: .update,
                data: data,
                returnsData: false
            )
            let updateStatus = try await performClient {
                try await client.update(updateRequest)
            }
            guard updateStatus == .success else {
                throw KeychainDeviceAuthorizationStoreError.keychainFailure
            }
        case .itemNotFound, .failure:
            throw KeychainDeviceAuthorizationStoreError.keychainFailure
        }
    }

    public func remove() async throws {
        let request = makeRequest(intent: .delete, data: nil, returnsData: false)
        let status = try await performClient {
            try await client.delete(request)
        }

        switch status {
        case .success, .itemNotFound:
            return
        case .duplicateItem, .failure:
            throw KeychainDeviceAuthorizationStoreError.keychainFailure
        }
    }

    private func makeRequest(
        intent: KeychainOperation,
        data: Data?,
        returnsData: Bool
    ) -> KeychainRequest {
        KeychainRequest(
            intent: intent,
            service: service,
            account: Self.account,
            data: data,
            returnsData: returnsData,
            accessibility: .whenUnlockedThisDeviceOnly,
            synchronizable: false,
            accessGroupIncluded: false
        )
    }

    private func performClient<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()

        do {
            let result = try await operation()
            try Task.checkCancellation()
            return result
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw KeychainDeviceAuthorizationStoreError.keychainFailure
        }
    }
}

#if canImport(Security)
/// The production Security implementation. All CF/Any values are constructed
/// inside the dedicated queue closure and never cross the Sendable seam.
private struct SystemKeychainDeviceAuthorizationStoreClient:
    KeychainDeviceAuthorizationStoreClient,
    Sendable
{
    private let queue: DispatchQueue

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.curves.lumi.keychain",
            qos: .userInitiated
        )
    ) {
        self.queue = queue
    }

    func add(_ request: KeychainRequest) async throws -> KeychainOperationStatus {
        try await execute {
            guard let data = request.data else { return errSecParam }
            return SecItemAdd(Self.addDictionary(for: request, data: data), nil)
        }
    }

    func copy(_ request: KeychainRequest) async throws -> KeychainCopyResult {
        try Task.checkCancellation()

        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<(OSStatus, Data?), Never>) in
            queue.async {
                var item: CFTypeRef?
                let status = SecItemCopyMatching(
                    Self.queryDictionary(for: request),
                    &item
                )
                let data = item as? Data
                continuation.resume(returning: (status, data))
            }
        }

        try Task.checkCancellation()
        return KeychainCopyResult(
            status: Self.map(result.0),
            data: result.1
        )
    }

    func update(_ request: KeychainRequest) async throws -> KeychainOperationStatus {
        guard let data = request.data else { return .failure }
        return try await execute {
            SecItemUpdate(
                Self.queryDictionary(for: request),
                [kSecValueData as String: data as Any] as CFDictionary
            )
        }
    }

    func delete(_ request: KeychainRequest) async throws -> KeychainOperationStatus {
        try await execute {
            SecItemDelete(Self.queryDictionary(for: request))
        }
    }

    private func execute(
        _ operation: @escaping @Sendable () -> OSStatus
    ) async throws -> KeychainOperationStatus {
        try Task.checkCancellation()

        let status = await withCheckedContinuation {
            (continuation: CheckedContinuation<OSStatus, Never>) in
            queue.async {
                continuation.resume(returning: operation())
            }
        }

        try Task.checkCancellation()
        return Self.map(status)
    }

    private static func map(_ status: OSStatus) -> KeychainOperationStatus {
        switch status {
        case errSecSuccess:
            .success
        case errSecDuplicateItem:
            .duplicateItem
        case errSecItemNotFound:
            .itemNotFound
        default:
            .failure
        }
    }

    // Apple Security docs: SecItemAdd/SecItemCopyMatching/SecItemUpdate/
    // SecItemDelete receive CFDictionary values; these dictionaries are built
    // only inside the queue closure that invokes those blocking APIs.
    private static func addDictionary(
        for request: KeychainRequest,
        data: Data
    ) -> CFDictionary {
        var dictionary: [String: Any] = baseDictionary(for: request)
        dictionary[kSecValueData as String] = data as Any
        return dictionary as CFDictionary
    }

    private static func queryDictionary(for request: KeychainRequest) -> CFDictionary {
        var dictionary: [String: Any] = baseDictionary(for: request)
        if request.returnsData {
            dictionary[kSecReturnData as String] = kCFBooleanTrue as Any
            dictionary[kSecMatchLimit as String] = kSecMatchLimitOne as Any
        }
        return dictionary as CFDictionary
    }

    private static func baseDictionary(for request: KeychainRequest) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: request.service,
            kSecAttrAccount as String: request.account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
#else
private struct SystemKeychainDeviceAuthorizationStoreClient:
    KeychainDeviceAuthorizationStoreClient,
    Sendable
{
    func add(_: KeychainRequest) async throws -> KeychainOperationStatus { .failure }
    func copy(_: KeychainRequest) async throws -> KeychainCopyResult {
        KeychainCopyResult(status: .failure, data: nil)
    }
    func update(_: KeychainRequest) async throws -> KeychainOperationStatus { .failure }
    func delete(_: KeychainRequest) async throws -> KeychainOperationStatus { .failure }
}
#endif
