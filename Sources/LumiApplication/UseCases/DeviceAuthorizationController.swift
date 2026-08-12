/// The current provisioning state for the active device authorization store.
public enum DeviceAuthorizationStatus: Equatable, Sendable {
    case missing
    case provisioned
}

/// Fixed, provider-neutral failures for device authorization operations.
public enum DeviceAuthorizationControllerError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case invalidToken
    case storageFailure

    public var description: String {
        switch self {
        case .invalidToken:
            "invalidToken"
        case .storageFailure:
            "storageFailure"
        }
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, unlabeledChildren: [], displayStyle: .enum)
    }
}

/// Application use case for provisioning and resetting device authorization.
public struct DeviceAuthorizationController: Sendable {
    private let store: any DeviceAuthorizationStore

    public init(store: any DeviceAuthorizationStore) {
        self.store = store
    }

    /// Reports whether the injected store currently contains a token.
    public func authorizationStatus() async throws -> DeviceAuthorizationStatus {
        try Task.checkCancellation()

        do {
            let token = try await store.load()
            try Task.checkCancellation()
            return token == nil ? .missing : .provisioned
        } catch {
            if error is CancellationError || Task.isCancelled {
                if error is CancellationError {
                    throw error
                }
                throw CancellationError()
            }
            throw DeviceAuthorizationControllerError.storageFailure
        }
    }

    /// Validates and persists a raw token through the injected store.
    public func save(rawValue: String) async throws {
        try Task.checkCancellation()

        guard let token = DeviceAuthorizationToken(rawValue: rawValue) else {
            throw DeviceAuthorizationControllerError.invalidToken
        }

        try Task.checkCancellation()

        do {
            try await store.save(token)
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled {
                if error is CancellationError {
                    throw error
                }
                throw CancellationError()
            }
            throw DeviceAuthorizationControllerError.storageFailure
        }
    }

    /// Removes the current token through the injected store.
    public func reset() async throws {
        try Task.checkCancellation()

        do {
            try await store.remove()
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled {
                if error is CancellationError {
                    throw error
                }
                throw CancellationError()
            }
            throw DeviceAuthorizationControllerError.storageFailure
        }
    }
}
