import Foundation
import LumiApplication
import LumiDomain
import Observation

/// The lifecycle shown by the DEBUG-Live member-memory management surface.
public enum MemberMemoryManagementState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case error(message: String)
}

/// Presentation-owned row data for the local member-memory management list.
/// The opaque `id` is used only to route an action back through this model; it
/// is never rendered as member-facing copy.
public struct MemberMemoryManagementRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let spokenLabel: String
    public let isMemoryEnabled: Bool

    public init(
        id: String,
        spokenLabel: String,
        isMemoryEnabled: Bool
    ) {
        self.id = id
        self.spokenLabel = spokenLabel
        self.isMemoryEnabled = isMemoryEnabled
    }
}

/// DEBUG-Live operator model for independently consented interaction memory.
///
/// This model is the only surface used by `LumiUI`. It maps Application
/// profiles into presentation rows, keeps the opaque member IDs internal, and
/// asks the App composition to invalidate the active session before every
/// consent or clear mutation.
@MainActor
@Observable
public final class MemberMemoryManagementModel {
    public static let memberConsentRequiredMessage = "啟用前請先確認已向會員說明並取得同意"
    public static let loadFailureMessage = "會員記憶載入失敗，請再試一次"
    public static let operationFailureMessage = "會員記憶操作失敗，請再試一次"
    public static let enabledMessage = "會員記憶已啟用"
    public static let disabledMessage = "會員記憶已停用"
    public static let clearedMessage = "本功能記憶已清除"

    public private(set) var state: MemberMemoryManagementState = .idle
    public private(set) var rows: [MemberMemoryManagementRow] = []
    public private(set) var isOperating = false
    public private(set) var statusMessage: String?

    @ObservationIgnored
    private let managementProfilesUseCase: LoadMemberMemoryManagementProfilesUseCase

    @ObservationIgnored
    private let consentUseCase: SetMemberMemoryConsentUseCase

    @ObservationIgnored
    private let clearUseCase: ClearMemberMemoryUseCase

    @ObservationIgnored
    private let onBeforeMemoryMutation: @MainActor () async -> Bool

    @ObservationIgnored
    private let onAfterMemoryMutation: @MainActor () async -> Void

    @ObservationIgnored
    private var memberIDsByRowID: [String: MemberID] = [:]

    @ObservationIgnored
    private var requestGeneration: UInt64 = 0

    public init(
        store: any MemberInteractionMemoryStore,
        directory: any MemberMemoryProfileDirectory,
        consentUseCase: SetMemberMemoryConsentUseCase,
        clearUseCase: ClearMemberMemoryUseCase,
        onBeforeMemoryMutation: @escaping @MainActor () async -> Bool,
        onAfterMemoryMutation: @escaping @MainActor () async -> Void = {}
    ) {
        self.managementProfilesUseCase = LoadMemberMemoryManagementProfilesUseCase(
            store: store,
            directory: directory
        )
        self.consentUseCase = consentUseCase
        self.clearUseCase = clearUseCase
        self.onBeforeMemoryMutation = onBeforeMemoryMutation
        self.onAfterMemoryMutation = onAfterMemoryMutation
    }

    /// Loads the registered member labels and their independent memory state.
    /// Storage details are intentionally reduced to a short retryable message.
    public func load() async {
        guard !isOperating else { return }

        requestGeneration &+= 1
        let generation = requestGeneration
        state = .loading
        statusMessage = nil

        do {
            let profiles = try await managementProfilesUseCase.execute()
            guard generation == requestGeneration else { return }
            var mappedRows: [MemberMemoryManagementRow] = []
            var mappedIDs: [String: MemberID] = [:]

            for profile in profiles {
                let rowID = profile.memberID.rawValue
                guard mappedIDs[rowID] == nil else { continue }

                mappedIDs[rowID] = profile.memberID
                mappedRows.append(
                    MemberMemoryManagementRow(
                        id: rowID,
                        spokenLabel: profile.spokenLabel,
                        isMemoryEnabled: profile.consent.isEnabled
                    )
                )
            }

            rows = mappedRows
            memberIDsByRowID = mappedIDs
            state = .ready
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            rows = []
            memberIDsByRowID = [:]
            state = .error(message: Self.loadFailureMessage)
            statusMessage = Self.loadFailureMessage
        } catch {
            guard generation == requestGeneration else { return }
            rows = []
            memberIDsByRowID = [:]
            state = .error(message: Self.loadFailureMessage)
            statusMessage = Self.loadFailureMessage
        }
    }

    /// Enables or disables memory for a known row. Enabling requires an
    /// explicit operator confirmation that the member was informed and gave
    /// consent; the operator action is not treated as member consent itself.
    public func setMemoryEnabled(
        for rowID: String,
        enabled: Bool,
        managerConfirmedMemberConsent: Bool = false
    ) async {
        guard !isOperating else { return }

        guard let memberID = memberIDsByRowID[rowID] else {
            statusMessage = Self.operationFailureMessage
            return
        }

        guard !enabled || managerConfirmedMemberConsent else {
            statusMessage = Self.memberConsentRequiredMessage
            return
        }

        requestGeneration &+= 1
        isOperating = true
        statusMessage = nil
        defer { isOperating = false }

        guard await onBeforeMemoryMutation() else {
            statusMessage = Self.operationFailureMessage
            return
        }

        do {
            try await consentUseCase.execute(
                for: memberID,
                enabled: enabled,
                at: Date()
            )
            updateRow(rowID: rowID, isMemoryEnabled: enabled)
            state = .ready
            statusMessage = enabled ? Self.enabledMessage : Self.disabledMessage
        } catch is CancellationError {
            state = .ready
            statusMessage = Self.operationFailureMessage
        } catch {
            state = .ready
            statusMessage = Self.operationFailureMessage
        }

        await onAfterMemoryMutation()
    }

    /// Clears only structured interaction-memory data. Identity records remain
    /// outside this use case and are therefore unaffected.
    public func clearMemory(for rowID: String) async {
        guard !isOperating else { return }

        guard let memberID = memberIDsByRowID[rowID] else {
            statusMessage = Self.operationFailureMessage
            return
        }

        requestGeneration &+= 1
        isOperating = true
        statusMessage = nil
        defer { isOperating = false }

        guard await onBeforeMemoryMutation() else {
            statusMessage = Self.operationFailureMessage
            return
        }

        do {
            try await clearUseCase.execute(for: memberID)
            state = .ready
            statusMessage = Self.clearedMessage
        } catch is CancellationError {
            state = .ready
            statusMessage = Self.operationFailureMessage
        } catch {
            state = .ready
            statusMessage = Self.operationFailureMessage
        }

        await onAfterMemoryMutation()
    }

    private func updateRow(rowID: String, isMemoryEnabled: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let row = rows[index]
        rows[index] = MemberMemoryManagementRow(
            id: row.id,
            spokenLabel: row.spokenLabel,
            isMemoryEnabled: isMemoryEnabled
        )
    }
}

private extension MemberMemoryConsentStatus {
    var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }
}
