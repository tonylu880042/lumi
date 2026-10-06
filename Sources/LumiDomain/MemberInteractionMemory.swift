import Foundation

/// The source of a fact kept in Lumi's local interaction memory.
public enum MemberMemorySource: Equatable, Sendable {
    case lumiObserved
    case memberReported
}

/// The bounded kinds of facts supported by the first interaction-memory slice.
public enum MemberMemoryEventKind: Equatable, Sendable {
    case meeting
    case exerciseDisclosure
}

/// A member's volunteered exercise state and its approved lifetime.
public enum MemberExerciseDisclosure: Equatable, Sendable {
    case preparing
    case justCompleted
    case completedToday

    public enum PersistenceScope: String, Equatable, Sendable {
        case session
        case day
    }

    public var persistenceScope: PersistenceScope {
        switch self {
        case .preparing, .justCompleted:
            .session
        case .completedToday:
            .day
        }
    }

    public var isPersistent: Bool {
        persistenceScope == .day
    }

}

/// One structured local-memory event. Free-form transcripts and audio are not
/// represented by this value.
public struct MemberMemoryEvent: Equatable, Sendable {
    public let eventID: String
    public let interactionID: String
    public let kind: MemberMemoryEventKind
    public let source: MemberMemorySource
    public let recordedAt: Date
    public let exerciseDisclosure: MemberExerciseDisclosure?

    public init(
        eventID: String,
        interactionID: String,
        kind: MemberMemoryEventKind,
        source: MemberMemorySource,
        recordedAt: Date,
        exerciseDisclosure: MemberExerciseDisclosure?
    ) {
        self.eventID = eventID
        self.interactionID = interactionID
        self.kind = kind
        self.source = source
        self.recordedAt = recordedAt
        self.exerciseDisclosure = exerciseDisclosure
    }
}

/// The one personal context that may be selected for a returning member's
/// opening. The current interaction is deliberately not included yet.
public enum MemberMemoryHighlight: Equatable, Sendable {
    case seenToday
    case frequentMeeting
    case longAbsent
}

/// Facts derived from still-retained meeting events before the current event
/// is written.
public struct MemberMemorySnapshot: Equatable, Sendable {
    public let lastMeetingAt: Date?
    public let hasSeenToday: Bool
    public let recentMeetingDayCount: Int
    /// Distinct observed dates in the current Monday–Sunday store week.
    /// This counts retained Lumi observations, not verified workouts.
    public let weeklyMeetingDayCount: Int
    /// First arrival's observed week ordinal, including this encounter.
    /// This does not persist the unfinished greeting into historical counts.
    public let arrivalWeeklyMeetingDayCount: Int?
    /// Earliest retained observed greeting on the current store date.
    public let firstMeetingTodayAt: Date?
    /// A later recognized encounter may use departure encouragement.
    public let isDepartureEncouragementEligible: Bool
    public let isLongAbsent: Bool
    public let primaryHighlight: MemberMemoryHighlight?
    public let currentExerciseDisclosure: MemberExerciseDisclosure?
    public let currentExerciseDisclosureRecordedAt: Date?

    public init(
        lastMeetingAt: Date?,
        hasSeenToday: Bool,
        recentMeetingDayCount: Int,
        isLongAbsent: Bool,
        primaryHighlight: MemberMemoryHighlight?,
        currentExerciseDisclosure: MemberExerciseDisclosure? = nil,
        currentExerciseDisclosureRecordedAt: Date? = nil,
        weeklyMeetingDayCount: Int = 0,
        firstMeetingTodayAt: Date? = nil,
        isDepartureEncouragementEligible: Bool = false,
        arrivalWeeklyMeetingDayCount: Int? = nil
    ) {
        self.lastMeetingAt = lastMeetingAt
        self.hasSeenToday = hasSeenToday
        self.recentMeetingDayCount = max(0, recentMeetingDayCount)
        self.weeklyMeetingDayCount = max(0, weeklyMeetingDayCount)
        self.arrivalWeeklyMeetingDayCount = arrivalWeeklyMeetingDayCount
            .flatMap { (1...7).contains($0) ? $0 : nil }
        self.firstMeetingTodayAt = firstMeetingTodayAt
        self.isDepartureEncouragementEligible = isDepartureEncouragementEligible
        self.isLongAbsent = isLongAbsent
        self.primaryHighlight = primaryHighlight
        self.currentExerciseDisclosure = currentExerciseDisclosure
        self.currentExerciseDisclosureRecordedAt =
            currentExerciseDisclosure == .completedToday
                ? currentExerciseDisclosureRecordedAt
                : nil
    }
}

/// Pure policy for the approved local-memory windows and thresholds.
public struct MemberInteractionMemoryPolicy: Sendable {
    public static let retentionDays = 90
    public static let recentWindowDays = 7
    public static let frequentMeetingDayThreshold = 3
    public static let longAbsenceDayThreshold = 14
    public static let departureMinimumElapsedSeconds: TimeInterval = 30 * 60

    public init() {}

    /// Derives a pre-write snapshot. Future timestamps and events older than
    /// the retention period cannot create a member-facing conclusion.
    public func snapshot(
        from events: [MemberMemoryEvent],
        at now: Date,
        timeZone: TimeZone = Self.storeTimeZone
    ) -> MemberMemorySnapshot {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            return emptySnapshot()
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        guard let retentionCutoff = calendar.date(
            byAdding: .day,
            value: -Self.retentionDays,
            to: now
        ) else {
            return emptySnapshot()
        }

        let meetings = events
            .filter { event in
                event.kind == .meeting
                    && event.recordedAt.timeIntervalSinceReferenceDate.isFinite
                    && event.recordedAt >= retentionCutoff
                    && event.recordedAt <= now
            }

        let currentExerciseDisclosureRecordedAt = events
            .filter { event in
                event.kind == .exerciseDisclosure
                    && event.source == .memberReported
                    && event.exerciseDisclosure == .completedToday
                    && event.recordedAt.timeIntervalSinceReferenceDate.isFinite
                    && event.recordedAt >= retentionCutoff
                    && event.recordedAt <= now
                    && calendar.isDate(event.recordedAt, inSameDayAs: now)
            }
            .map(\.recordedAt)
            .max()
        let currentExerciseDisclosure =
            currentExerciseDisclosureRecordedAt
                .map { _ in MemberExerciseDisclosure.completedToday }

        let lastMeetingAt = meetings.map(\.recordedAt).max()
        let today = calendar.startOfDay(for: now)
        let hasSeenToday = meetings.contains {
            calendar.isDate($0.recordedAt, inSameDayAs: today)
        }
        let firstMeetingTodayAt = meetings.filter {
            $0.source == .lumiObserved
                && calendar.isDate($0.recordedAt, inSameDayAs: today)
        }.map(\.recordedAt).min()

        let recentStart = calendar.date(
            byAdding: .day,
            value: -(Self.recentWindowDays - 1),
            to: today
        ) ?? today
        let recentDays = Set(
            meetings.compactMap { event -> Date? in
                let eventDay = calendar.startOfDay(for: event.recordedAt)
                guard eventDay >= recentStart, eventDay <= today else {
                    return nil
                }
                return eventDay
            }
        )

        // Gregorian weekday is Sunday = 1. Anchor explicitly to Monday so
        // device locale and ISO week-year changes cannot alter this window.
        let daysSinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
        let weekStart = calendar.date(
            byAdding: .day, value: -daysSinceMonday, to: today
        ) ?? today
        let weeklyDays = Set(
            meetings.filter {
                $0.source == .lumiObserved && $0.recordedAt >= weekStart
            }.map { calendar.startOfDay(for: $0.recordedAt) }
        )

        let isLongAbsent: Bool
        if let lastMeetingAt {
            let lastDay = calendar.startOfDay(for: lastMeetingAt)
            let elapsedDays = calendar.dateComponents(
                [.day],
                from: lastDay,
                to: today
            ).day ?? 0
            isLongAbsent = elapsedDays >= Self.longAbsenceDayThreshold
        } else {
            isLongAbsent = false
        }

        let primaryHighlight: MemberMemoryHighlight?
        if hasSeenToday {
            primaryHighlight = .seenToday
        } else if isLongAbsent {
            primaryHighlight = .longAbsent
        } else if recentDays.count >= Self.frequentMeetingDayThreshold {
            primaryHighlight = .frequentMeeting
        } else {
            primaryHighlight = nil
        }

        return MemberMemorySnapshot(
            lastMeetingAt: lastMeetingAt,
            hasSeenToday: hasSeenToday,
            recentMeetingDayCount: recentDays.count,
            isLongAbsent: isLongAbsent,
            primaryHighlight: primaryHighlight,
            currentExerciseDisclosure: currentExerciseDisclosure,
            currentExerciseDisclosureRecordedAt:
                currentExerciseDisclosureRecordedAt,
            weeklyMeetingDayCount: weeklyDays.count,
            firstMeetingTodayAt: firstMeetingTodayAt,
            isDepartureEncouragementEligible: Self.isDepartureEncouragementEligible(
                firstMeetingTodayAt: firstMeetingTodayAt, at: now, timeZone: timeZone
            ),
            arrivalWeeklyMeetingDayCount: firstMeetingTodayAt == nil
                ? weeklyDays.count + 1 : nil
        )
    }

    public static let storeTimeZone = TimeZone(identifier: "Asia/Taipei")!

    public static func isArrivalEncouragementActive(
        encounterAt: Date?, at now: Date,
        timeZone: TimeZone = storeTimeZone
    ) -> Bool {
        guard let encounterAt,
              encounterAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              encounterAt <= now else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.isDate(encounterAt, inSameDayAs: now)
    }

    /// Eligibility does not prove a workout or departure. Application applies
    /// it only after recognizing the member again in a later interaction.
    public static func isDepartureEncouragementEligible(
        firstMeetingTodayAt: Date?,
        at now: Date,
        timeZone: TimeZone = storeTimeZone
    ) -> Bool {
        guard let firstMeetingTodayAt,
              firstMeetingTodayAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSince(firstMeetingTodayAt) >= departureMinimumElapsedSeconds
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.isDate(firstMeetingTodayAt, inSameDayAs: now)
    }

    /// Applies the approved lifetime without exposing a date to the voice
    /// provider. Session-only states survive reconnects; `completedToday`
    /// requires a trustworthy timestamp on the same store-local day and fails
    /// closed for future timestamps or clock rollback.
    public static func isExerciseDisclosureActive(
        _ disclosure: MemberExerciseDisclosure,
        recordedAt: Date?,
        at now: Date,
        timeZone: TimeZone = storeTimeZone
    ) -> Bool {
        switch disclosure {
        case .preparing, .justCompleted:
            return true
        case .completedToday:
            guard let recordedAt,
                  recordedAt.timeIntervalSinceReferenceDate.isFinite,
                  now.timeIntervalSinceReferenceDate.isFinite,
                  recordedAt <= now
            else { return false }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar.isDate(recordedAt, inSameDayAs: now)
        }
    }

    private func emptySnapshot() -> MemberMemorySnapshot {
        MemberMemorySnapshot(
            lastMeetingAt: nil,
            hasSeenToday: false,
            recentMeetingDayCount: 0,
            isLongAbsent: false,
            primaryHighlight: nil,
            currentExerciseDisclosure: nil,
            currentExerciseDisclosureRecordedAt: nil
        )
    }
}
