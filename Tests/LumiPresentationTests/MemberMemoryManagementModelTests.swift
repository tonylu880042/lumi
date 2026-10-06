import Foundation
import LumiApplication
import LumiDomain
import Testing

@testable import LumiPresentation

@Suite("Member memory management model", .serialized)
@MainActor
struct MemberMemoryManagementModelTests {
    @Test("loads registered labels and maps consent to presentation rows")
    func loadsRegisteredMembers() async throws {
        let firstID = try MemberID(rawValue: "member-a")
        let secondID = try MemberID(rawValue: "member-b")
        let store = RecordingMemberMemoryStore(
            profiles: [
                MemberMemoryManagementProfile(
                    memberID: firstID,
                    spokenLabel: "小美",
                    consent: .enabled(consentedAt: Date(timeIntervalSince1970: 1))
                ),
                MemberMemoryManagementProfile(
                    memberID: secondID,
                    spokenLabel: "小芳",
                    consent: .disabled
                )
            ]
        )
        let model = makeModel(store: store)

        await model.load()

        #expect(model.state == .ready)
        #expect(model.rows == [
            MemberMemoryManagementRow(
                id: firstID.rawValue,
                spokenLabel: "小美",
                isMemoryEnabled: true
            ),
            MemberMemoryManagementRow(
                id: secondID.rawValue,
                spokenLabel: "小芳",
                isMemoryEnabled: false
            )
        ])
    }

    @Test("requires a separate manager confirmation before enabling member memory")
    func enablingRequiresManagerConfirmation() async throws {
        let memberID = try MemberID(rawValue: "member-a")
        let store = RecordingMemberMemoryStore(profiles: [
            MemberMemoryManagementProfile(
                memberID: memberID,
                spokenLabel: "小美",
                consent: .disabled
            )
        ])
        let model = makeModel(store: store)
        await model.load()

        await model.setMemoryEnabled(for: memberID.rawValue, enabled: true)

        #expect(model.statusMessage == MemberMemoryManagementModel.memberConsentRequiredMessage)
        #expect(model.rows.first?.isMemoryEnabled == false)
        #expect(await store.setConsentCalls.isEmpty)
    }

    @Test("invalidates the active session before enabling memory")
    func enablingInvalidatesSessionBeforeWrite() async throws {
        let memberID = try MemberID(rawValue: "member-a")
        let trace = OperationTrace()
        let store = RecordingMemberMemoryStore(
            profiles: [
                MemberMemoryManagementProfile(
                    memberID: memberID,
                    spokenLabel: "小美",
                    consent: .disabled
                )
            ],
            trace: trace
        )
        let model = makeModel(store: store) {
            await trace.append("invalidate")
            return true
        } onAfterMemoryMutation: {
            await trace.append("restart")
        }
        await model.load()

        await model.setMemoryEnabled(
            for: memberID.rawValue,
            enabled: true,
            managerConfirmedMemberConsent: true
        )

        #expect(await trace.values == ["invalidate", "setConsent", "restart"])
        #expect(await store.setConsentCalls.count == 1)
        #expect(model.rows.first?.isMemoryEnabled == true)
        #expect(model.statusMessage == MemberMemoryManagementModel.enabledMessage)
    }

    @Test("disabling memory updates the row without requiring member consent confirmation")
    func disablingMemory() async throws {
        let memberID = try MemberID(rawValue: "member-a")
        let store = RecordingMemberMemoryStore(profiles: [
            MemberMemoryManagementProfile(
                memberID: memberID,
                spokenLabel: "小美",
                consent: .enabled(consentedAt: Date(timeIntervalSince1970: 1))
            )
        ])
        var invalidationCount = 0
        let model = makeModel(store: store) {
            invalidationCount += 1
            return true
        }
        await model.load()

        await model.setMemoryEnabled(for: memberID.rawValue, enabled: false)

        #expect(invalidationCount == 1)
        #expect(model.rows.first?.isMemoryEnabled == false)
        #expect(await store.setConsentCalls.count == 1)
        #expect(await store.setConsentCalls.first?.1 == .disabled)
        #expect(model.statusMessage == MemberMemoryManagementModel.disabledMessage)
    }

    @Test("does not mutate memory when session shutdown preparation fails")
    func failedSessionPreparationDoesNotMutateMemory() async throws {
        let memberID = try MemberID(rawValue: "member-a")
        let store = RecordingMemberMemoryStore(profiles: [
            MemberMemoryManagementProfile(
                memberID: memberID,
                spokenLabel: "小美",
                consent: .enabled(consentedAt: Date(timeIntervalSince1970: 1))
            )
        ])
        let model = makeModel(store: store) { false }
        await model.load()

        await model.setMemoryEnabled(for: memberID.rawValue, enabled: false)

        #expect(await store.setConsentCalls.isEmpty)
        #expect(model.rows.first?.isMemoryEnabled == true)
        #expect(model.statusMessage == MemberMemoryManagementModel.operationFailureMessage)
    }

    @Test("a stale management read cannot restore consent after a later mutation")
    func staleLoadCannotRestoreConsent() async throws {
        let memberID = try MemberID(rawValue: "member-a")
        let store = RecordingMemberMemoryStore(profiles: [
            MemberMemoryManagementProfile(
                memberID: memberID,
                spokenLabel: "小美",
                consent: .enabled(consentedAt: Date(timeIntervalSince1970: 1))
            )
        ])
        let model = makeModel(store: store)
        await model.load()
        await store.suspendNextManagementRead()

        let staleLoad = Task { @MainActor in
            await model.load()
        }
        await store.waitForManagementRead()

        await model.setMemoryEnabled(for: memberID.rawValue, enabled: false)
        await store.releaseManagementRead()
        await staleLoad.value

        #expect(model.rows.first?.isMemoryEnabled == false)
        #expect(model.statusMessage == MemberMemoryManagementModel.disabledMessage)
    }

    @Test("mutation failures remain generic and do not report success")
    func mutationFailureIsGeneric() async throws {
        let memberID = try MemberID(rawValue: "member-a")
        let marker = "sqlite-secret-or-member-id"
        let store = RecordingMemberMemoryStore(
            profiles: [
                MemberMemoryManagementProfile(
                    memberID: memberID,
                    spokenLabel: "小美",
                    consent: .disabled
                )
            ],
            setConsentFailure: TestMemoryError(marker: marker)
        )
        let model = makeModel(store: store)
        await model.load()

        await model.setMemoryEnabled(
            for: memberID.rawValue,
            enabled: true,
            managerConfirmedMemberConsent: true
        )

        #expect(model.rows.first?.isMemoryEnabled == false)
        #expect(model.statusMessage == MemberMemoryManagementModel.operationFailureMessage)
        #expect(model.statusMessage != MemberMemoryManagementModel.enabledMessage)
        #expect(String(describing: model.statusMessage).contains(marker) == false)
    }

    @Test("invalidates the active session before clearing only interaction memory")
    func clearingInvalidatesSessionBeforeClear() async throws {
        let memberID = try MemberID(rawValue: "member-a")
        let trace = OperationTrace()
        let store = RecordingMemberMemoryStore(
            profiles: [
                MemberMemoryManagementProfile(
                    memberID: memberID,
                    spokenLabel: "小美",
                    consent: .enabled(consentedAt: Date(timeIntervalSince1970: 1))
                )
            ],
            trace: trace
        )
        let model = makeModel(store: store) {
            await trace.append("invalidate")
            return true
        } onAfterMemoryMutation: {
            await trace.append("restart")
        }
        await model.load()

        await model.clearMemory(for: memberID.rawValue)

        #expect(await trace.values == ["invalidate", "clearMemory", "restart"])
        #expect(await store.clearMemberIDs == [memberID])
        #expect(model.rows.first?.isMemoryEnabled == true)
        #expect(model.statusMessage == MemberMemoryManagementModel.clearedMessage)
    }

    @Test("maps storage failures to short redacted messages")
    func mapsStorageFailures() async throws {
        let marker = "sqlite-path-or-member-id"
        let store = RecordingMemberMemoryStore(
            profiles: [],
            failure: TestMemoryError(marker: marker)
        )
        let model = makeModel(store: store)

        await model.load()

        #expect(model.state == .error(message: MemberMemoryManagementModel.loadFailureMessage))
        #expect(model.statusMessage == MemberMemoryManagementModel.loadFailureMessage)
        #expect(String(describing: model.state).contains(marker) == false)
    }

    @Test("a failed profile refresh clears stale rows before showing the error")
    func failedRefreshClearsStaleRows() async throws {
        let memberID = try MemberID(rawValue: "member-a")
        let store = RecordingMemberMemoryStore(profiles: [
            MemberMemoryManagementProfile(
                memberID: memberID,
                spokenLabel: "小美",
                consent: .disabled
            )
        ])
        let model = makeModel(store: store)

        await model.load()
        #expect(model.rows.count == 1)

        await store.failManagementReads(with: TestMemoryError(marker: "identity-db-path"))
        await model.load()

        #expect(model.state == .error(message: MemberMemoryManagementModel.loadFailureMessage))
        #expect(model.rows.isEmpty)
        await model.setMemoryEnabled(
            for: memberID.rawValue,
            enabled: false
        )
        #expect(model.statusMessage == MemberMemoryManagementModel.operationFailureMessage)
        #expect(await store.setConsentCalls.isEmpty)
    }

    private func makeModel(
        store: RecordingMemberMemoryStore,
        onBeforeMemoryMutation: @escaping @MainActor () async -> Bool = { true },
        onAfterMemoryMutation: @escaping @MainActor () async -> Void = {}
    ) -> MemberMemoryManagementModel {
        MemberMemoryManagementModel(
            store: store,
            directory: store,
            consentUseCase: SetMemberMemoryConsentUseCase(store: store),
            clearUseCase: ClearMemberMemoryUseCase(store: store),
            onBeforeMemoryMutation: onBeforeMemoryMutation,
            onAfterMemoryMutation: onAfterMemoryMutation
        )
    }
}

private actor OperationTrace {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private struct TestMemoryError: Error, CustomStringConvertible, Sendable {
    let marker: String

    var description: String { marker }
}

private actor RecordingMemberMemoryStore:
    MemberInteractionMemoryStore,
    MemberMemoryProfileDirectory
{
    private var profiles: [MemberMemoryManagementProfile]
    private var failure: TestMemoryError?
    private let setConsentFailure: TestMemoryError?
    private let trace: OperationTrace?

    private var suspendNextRead = false
    private var managementReadEntered = false
    private var managementReadContinuation: CheckedContinuation<Void, Never>?

    private(set) var setConsentCalls: [(MemberID, MemberMemoryConsentStatus)] = []
    private(set) var clearMemberIDs: [MemberID] = []

    init(
        profiles: [MemberMemoryManagementProfile],
        failure: TestMemoryError? = nil,
        setConsentFailure: TestMemoryError? = nil,
        trace: OperationTrace? = nil
    ) {
        self.profiles = profiles
        self.failure = failure
        self.setConsentFailure = setConsentFailure
        self.trace = trace
    }

    func consentStatus(for memberID: MemberID) async throws -> MemberMemoryConsentStatus {
        if let failure { throw failure }
        return profiles.first(where: { $0.memberID == memberID })?.consent ?? .disabled
    }

    func loadBatch(
        for _: MemberID,
        at _: Date
    ) async throws -> MemberMemoryEventBatch {
        if let failure { throw failure }
        return MemberMemoryEventBatch(events: [], revision: 0)
    }

    func append(
        _: MemberMemoryEvent,
        for _: MemberID,
        expectedRevision: UInt64
    ) async throws -> MemberMemoryAppendResult {
        if let failure { throw failure }
        return MemberMemoryAppendResult(outcome: .appended, revision: expectedRevision + 1)
    }

    func setConsent(
        for memberID: MemberID,
        status: MemberMemoryConsentStatus
    ) async throws {
        if let setConsentFailure { throw setConsentFailure }
        await trace?.append("setConsent")
        setConsentCalls.append((memberID, status))
        guard let index = profiles.firstIndex(where: { $0.memberID == memberID }) else { return }
        profiles[index] = MemberMemoryManagementProfile(
            memberID: memberID,
            spokenLabel: profiles[index].spokenLabel,
            consent: status
        )
    }

    func clearMemory(for memberID: MemberID) async throws {
        if let failure { throw failure }
        await trace?.append("clearMemory")
        clearMemberIDs.append(memberID)
    }

    func managementProfiles() async throws -> [MemberMemoryManagementProfile] {
        if let failure { throw failure }
        if suspendNextRead {
            suspendNextRead = false
            managementReadEntered = true
            await withCheckedContinuation { continuation in
                managementReadContinuation = continuation
            }
        }
        return profiles
    }

    func memberMemoryProfiles() async throws -> [MemberMemoryProfile] {
        if let failure { throw failure }
        if suspendNextRead {
            suspendNextRead = false
            managementReadEntered = true
            await withCheckedContinuation { continuation in
                managementReadContinuation = continuation
            }
        }
        return profiles.map { profile in
            MemberMemoryProfile(
                memberID: profile.memberID,
                spokenLabel: profile.spokenLabel
            )
        }
    }

    func suspendNextManagementRead() {
        suspendNextRead = true
        managementReadEntered = false
    }

    func waitForManagementRead() async {
        while !managementReadEntered {
            await Task.yield()
        }
    }

    func releaseManagementRead() {
        managementReadContinuation?.resume()
        managementReadContinuation = nil
    }

    func failManagementReads(with error: TestMemoryError) {
        failure = error
    }
}
