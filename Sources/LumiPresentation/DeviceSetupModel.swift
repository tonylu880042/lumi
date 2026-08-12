import LumiApplication
import Observation

/// The user-visible lifecycle of Live device authorization setup.
public enum DeviceSetupState: Equatable, Sendable {
    case loading
    case setup(message: String?)
    case saving
    case ready
    case failure(message: String)
}

/// Presentation-owned setup state for the active device-authorization store.
///
/// The model never loads a stored token for display. `tokenInput` is only the
/// transient value currently being edited by the setup view and is cleared at
/// the approved success, reset, and cancellation boundaries.
@MainActor
@Observable
public final class DeviceSetupModel {
    public typealias State = DeviceSetupState

    public static let invalidInputMessage = "請輸入有效的裝置授權"
    public static let retryableFailureMessage = "裝置設定失敗，請再試一次"
    public static let authorizationInvalidMessage = "裝置授權已失效"

    public private(set) var state: DeviceSetupState = .loading
    public var tokenInput = ""
    public private(set) var isResetConfirmationPresented = false

    @ObservationIgnored
    private let controller: DeviceAuthorizationController

    public init(controller: DeviceAuthorizationController) {
        self.controller = controller
    }

    /// Loads only the current provisioned/missing status; no stored secret is
    /// copied into Presentation state.
    public func load() async {
        state = .loading
        tokenInput = ""

        do {
            switch try await controller.authorizationStatus() {
            case .missing:
                state = .setup(message: nil)
            case .provisioned:
                state = .ready
            }
        } catch {
            state = .failure(message: Self.retryableFailureMessage)
        }
    }

    /// Validates and saves the transient input through the Application use
    /// case. Invalid input remains editable in setup; storage failures remain
    /// retryable without placing a secret or provider detail in UI state.
    public func save() async {
        guard state != .loading, state != .saving else { return }

        guard !tokenInput.isEmpty else {
            state = .setup(message: Self.invalidInputMessage)
            return
        }

        state = .saving

        do {
            try await controller.save(rawValue: tokenInput)
            tokenInput = ""
            state = .ready
        } catch DeviceAuthorizationControllerError.invalidToken {
            state = .setup(message: Self.invalidInputMessage)
        } catch is CancellationError {
            tokenInput = ""
            state = .failure(message: Self.retryableFailureMessage)
        } catch {
            state = .failure(message: Self.retryableFailureMessage)
        }
    }

    /// Requests confirmation before deleting the active environment's token.
    public func requestReset() {
        guard state != .loading, state != .saving else { return }
        isResetConfirmationPresented = true
    }

    /// Dismisses reset confirmation without touching the injected store.
    public func cancelReset() {
        isResetConfirmationPresented = false
        tokenInput = ""
    }

    /// Deletes only through the injected Application controller after the
    /// confirmation intent has been presented.
    public func confirmReset() async {
        guard isResetConfirmationPresented else { return }
        isResetConfirmationPresented = false

        do {
            try await controller.reset()
            tokenInput = ""
            state = .setup(message: nil)
        } catch {
            tokenInput = ""
            state = .failure(message: Self.retryableFailureMessage)
        }
    }

    /// Routes a semantic broker authorization invalidation to setup without
    /// exposing HTTP/provider details.
    public func authorizationInvalidated() {
        isResetConfirmationPresented = false
        tokenInput = ""
        state = .setup(message: Self.authorizationInvalidMessage)
    }

    /// Begins reconfiguration from the authorization-invalid state without
    /// changing the persisted device authorization.
    public func beginReconfiguration() {
        guard state == .setup(message: Self.authorizationInvalidMessage) else {
            return
        }

        isResetConfirmationPresented = false
        tokenInput = ""
        state = .setup(message: nil)
    }
}
