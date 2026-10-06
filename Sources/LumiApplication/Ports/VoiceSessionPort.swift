import Foundation
import LumiDomain

/// Privacy-safe context used to choose the generic Phase 1 greeting.
///
/// Voice is currently limited to Taiwan Mandarin and the application does
/// not expose language selection or member details at this boundary.
public enum VoiceContext: Equatable, Sendable {
    case returningMember
    case visitor
}

/// Bounded historical highlights allowed to cross into a voice provider.
/// It contains no ID, date, count, transcript, or health detail.
public enum VoiceMemberMemoryHighlight: String, Equatable, Sendable {
    case seenToday
    case frequentMeeting
    case longAbsent
}

public struct VoiceMemberMemoryContext: Equatable, Sendable {
    public let highlight: VoiceMemberMemoryHighlight?
    /// The first arrival's observed weekly ordinal, including this encounter.
    public let arrivalWeeklyMeetingDayCount: Int?
    private let arrivalEncounterAt: Date?
    /// Only an eligible later encounter may disclose this observed weekly
    /// count. Member identity and the first record's timestamp stay local.
    public let departureWeeklyMeetingDayCount: Int?
    private let departureFirstMeetingAt: Date?
    public let currentExerciseDisclosure: MemberExerciseDisclosure?
    /// Local validity metadata. Prompt builders can only read the bounded enum;
    /// the source timestamp remains private and is never encoded for a provider.
    private let currentExerciseDisclosureRecordedAt: Date?

    public init(
        highlight: VoiceMemberMemoryHighlight?,
        currentExerciseDisclosure: MemberExerciseDisclosure? = nil,
        currentExerciseDisclosureRecordedAt: Date? = nil,
        departureWeeklyMeetingDayCount: Int? = nil,
        departureFirstMeetingAt: Date? = nil,
        arrivalWeeklyMeetingDayCount: Int? = nil,
        arrivalEncounterAt: Date? = nil
    ) {
        self.highlight = highlight
        self.arrivalWeeklyMeetingDayCount = arrivalWeeklyMeetingDayCount
            .flatMap { (1...7).contains($0) ? $0 : nil }
        self.arrivalEncounterAt = arrivalEncounterAt
        self.departureWeeklyMeetingDayCount = departureWeeklyMeetingDayCount
            .flatMap { (1...7).contains($0) ? $0 : nil }
        self.departureFirstMeetingAt = departureFirstMeetingAt
        self.currentExerciseDisclosure = currentExerciseDisclosure
        self.currentExerciseDisclosureRecordedAt =
            currentExerciseDisclosure == .completedToday
                ? currentExerciseDisclosureRecordedAt
                : nil
    }

    public init(snapshot: MemberMemorySnapshot, encounterAt: Date? = nil) {
        self.init(
            snapshot: snapshot,
            currentExerciseState: MemberExerciseDisclosureSessionState(
                disclosure: snapshot.currentExerciseDisclosure,
                recordedAt: snapshot.currentExerciseDisclosureRecordedAt
            ),
            encounterAt: encounterAt
        )
    }

    init(
        snapshot: MemberMemorySnapshot,
        currentExerciseState: MemberExerciseDisclosureSessionState,
        encounterAt: Date? = nil
    ) {
        let mappedHighlight: VoiceMemberMemoryHighlight?
        switch snapshot.primaryHighlight {
        case .seenToday:
            mappedHighlight = .seenToday
        case .frequentMeeting:
            mappedHighlight = .frequentMeeting
        case .longAbsent:
            mappedHighlight = .longAbsent
        case nil:
            mappedHighlight = nil
        }
        self.init(
            highlight: mappedHighlight,
            currentExerciseDisclosure: currentExerciseState.disclosure,
            currentExerciseDisclosureRecordedAt:
                currentExerciseState.recordedAt,
            departureWeeklyMeetingDayCount: snapshot.isDepartureEncouragementEligible
                ? snapshot.weeklyMeetingDayCount : nil,
            departureFirstMeetingAt: snapshot.isDepartureEncouragementEligible
                ? snapshot.firstMeetingTodayAt : nil,
            arrivalWeeklyMeetingDayCount: encounterAt == nil
                ? nil : snapshot.arrivalWeeklyMeetingDayCount,
            arrivalEncounterAt: encounterAt
        )
    }

    /// Returns the context that is valid at `now`. The Domain policy owns the
    /// Asia/Taipei date boundary; provider-facing code receives no timestamp.
    public func effective(at now: Date) -> Self {
        let disclosure = currentExerciseDisclosure.flatMap {
            MemberInteractionMemoryPolicy.isExerciseDisclosureActive(
                $0, recordedAt: currentExerciseDisclosureRecordedAt, at: now
            ) ? $0 : nil
        }
        let departureIsValid = MemberInteractionMemoryPolicy.isDepartureEncouragementEligible(
            firstMeetingTodayAt: departureFirstMeetingAt, at: now
        )
        let arrivalIsValid = MemberInteractionMemoryPolicy.isArrivalEncouragementActive(
            encounterAt: arrivalEncounterAt, at: now
        )
        return Self(
            highlight: highlight,
            currentExerciseDisclosure: disclosure,
            currentExerciseDisclosureRecordedAt: currentExerciseDisclosureRecordedAt,
            departureWeeklyMeetingDayCount: departureIsValid ? departureWeeklyMeetingDayCount : nil,
            departureFirstMeetingAt: departureIsValid ? departureFirstMeetingAt : nil,
            arrivalWeeklyMeetingDayCount: arrivalIsValid ? arrivalWeeklyMeetingDayCount : nil,
            arrivalEncounterAt: arrivalIsValid ? arrivalEncounterAt : nil
        )
    }

    public func updatingExerciseDisclosure(
        _ disclosure: MemberExerciseDisclosure?, recordedAt: Date?
    ) -> Self {
        Self(
            highlight: highlight,
            currentExerciseDisclosure: disclosure,
            currentExerciseDisclosureRecordedAt: recordedAt,
            departureWeeklyMeetingDayCount: departureWeeklyMeetingDayCount,
            departureFirstMeetingAt: departureFirstMeetingAt,
            arrivalWeeklyMeetingDayCount: arrivalWeeklyMeetingDayCount,
            arrivalEncounterAt: arrivalEncounterAt
        )
    }

    public var hasPersonalizedOpening: Bool {
        highlight != nil || departureWeeklyMeetingDayCount != nil
            || arrivalWeeklyMeetingDayCount != nil
    }
}

/// Provider-neutral direction for one voice conversation.
///
/// The direction carries no member identity, profile, recognition confidence,
/// or exercise data. It only selects the conversation focus for the current
/// voice session.
public enum VoiceConversationDirection: Equatable, Sendable {
    case general
    case preWorkoutReminder
    case postWorkoutReview
}

/// A deliberately narrow, provider-neutral label that voice may speak.
///
/// This value is not a member profile and carries no exercise, recognition,
/// or biometric data. Its restricted alphabet keeps an enrollment identifier
/// from becoming free-form prompt text at the provider boundary.
public struct VoiceMemberAddress: Equatable, Sendable {
    public let spokenLabel: String

    public init(spokenLabel: String) throws(VoiceMemberAddressError) {
        guard
            !spokenLabel.isEmpty,
            spokenLabel.count <= 32,
            spokenLabel.allSatisfy({ character in
                character.isLetter
                    || character.isNumber
            })
        else {
            throw VoiceMemberAddressError.invalid
        }

        self.spokenLabel = spokenLabel
    }
}

/// Fixed, payload-free validation failure for a spoken member label.
public enum VoiceMemberAddressError: Error, Equatable, Sendable {
    case invalid
}

/// Semantic lifecycle events emitted by a voice session.
///
/// Provider errors and payloads stay behind the Infrastructure adapter. The
/// coordinator uses `.failure` for generic retry behavior and
/// `.authorizationRequired` for device setup routing.
public enum VoiceSessionEvent: Equatable, Sendable {
    /// Assistant audio reached the device output path.
    case assistantOutputStarted
    /// The current assistant audio output finished or was cleared.
    case assistantOutputEnded
    /// The provider cleared current output without a confirmed natural stop.
    /// This boundary is intentionally distinct so a generated opener cannot
    /// be counted as a completed greeting after cancellation or barge-in.
    case assistantOutputCleared
    /// A local or provider opening completed successfully and the session is
    /// ready to count one meeting.
    case greetingCompleted
    /// The visitor clearly ended the current conversation. The event carries
    /// no transcript or provider payload; the Application owns teardown.
    case conversationEndRequested
    /// The user started speaking while the assistant was producing audio.
    ///
    /// Provider adapters emit this event instead of also emitting
    /// `userSpeechStarted` for the same interruption.
    case assistantInterrupted
    case userSpeechStarted
    case userSpeechEnded
    case responseReady
    case failure
    /// The current device credential must be provisioned again.
    case authorizationRequired
}

/// Semantic signal that the current device must be provisioned again.
public enum VoiceSessionAuthorizationError: Error, Equatable, Sendable {
    case authorizationRequired
}

/// Application boundary for a provider-independent voice session.
public protocol VoiceSessionPort: Sendable {
    /// Returns only after the voice session is ready for conversation.
    func start(context: VoiceContext) async throws

    /// Returns only after the voice session is ready for conversation, using
    /// the requested provider-neutral direction.
    func start(
        context: VoiceContext,
        direction: VoiceConversationDirection
    ) async throws

    /// Returns only after the voice session is ready, optionally allowing a
    /// previously validated address label for a confirmed returning member.
    func start(
        context: VoiceContext,
        direction: VoiceConversationDirection,
        memberAddress: VoiceMemberAddress?
    ) async throws

    /// Starts with a minimum historical context selected by Application.
    func start(
        context: VoiceContext,
        direction: VoiceConversationDirection,
        memberAddress: VoiceMemberAddress?,
        memoryContext: VoiceMemberMemoryContext?
    ) async throws

    /// Registers an independent subscriber for subsequent semantic events.
    func eventUpdates() async -> AsyncStream<VoiceSessionEvent>

    /// Ends the current voice session. Calling this repeatedly is safe.
    func stop() async

    /// Pre-warms or prepares underlying voice resources.
    func prewarm() async

    /// Removes any already-loaded member context from the active provider
    /// session after a management clear/disable.
    func invalidateMemberMemoryContext() async

    /// Updates the bounded current-session disclosure after the Application
    /// accepts a member's explicit statement. Implementations may refresh
    /// provider instructions for a reconnect without exposing identity data.
    func updateMemberMemoryContext(_ context: VoiceMemberMemoryContext) async
}

public extension VoiceSessionPort {
    func prewarm() async {}

    /// Preserves the original start contract as the general direction.
    func start(
        context: VoiceContext,
        direction _: VoiceConversationDirection
    ) async throws {
        try await start(context: context)
    }

    /// Existing ports remain anonymous until their composition explicitly
    /// opts into the narrow member-address contract.
    func start(
        context: VoiceContext,
        direction: VoiceConversationDirection,
        memberAddress _: VoiceMemberAddress?
    ) async throws {
        try await start(context: context, direction: direction)
    }

    func start(
        context: VoiceContext,
        direction: VoiceConversationDirection,
        memberAddress: VoiceMemberAddress?,
        memoryContext _: VoiceMemberMemoryContext?
    ) async throws {
        try await start(
            context: context,
            direction: direction,
            memberAddress: memberAddress
        )
    }

    func invalidateMemberMemoryContext() async {}

    func updateMemberMemoryContext(_: VoiceMemberMemoryContext) async {}
}
