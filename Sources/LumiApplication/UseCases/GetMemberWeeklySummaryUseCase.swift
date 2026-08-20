import Foundation
import LumiDomain

/// Fixed, provider-neutral failures for the weekly summary tool use case.
public enum GetMemberWeeklySummaryError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    /// The repository could not provide the requested summary.
    case repositoryUnavailable

    /// The repository returned data that cannot cross the tool boundary.
    case invalidData

    public var description: String {
        switch self {
        case .repositoryUnavailable:
            "repositoryUnavailable"
        case .invalidData:
            "invalidData"
        }
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, unlabeledChildren: [], displayStyle: .enum)
    }
}

/// The minimum exercise data exposed by the weekly-summary tool.
public struct MemberWeeklySummaryToolResult: Equatable, Sendable {
    public let visitsThisWeek: Int
    public let activityMETMinutes: Double?
    public let lastWorkoutAt: Date?
    public let todayCompleted: Bool
    private let canonicalJSON: Data

    /// Returns canonical UTF-8 JSON for the provider-neutral tool contract.
    ///
    /// Optional values are always represented by explicit JSON `null` values.
    /// Keys are sorted and no insignificant whitespace is emitted.
    public func jsonData() -> Data {
        canonicalJSON
    }

    fileprivate init(summary: ExerciseSummary) throws(GetMemberWeeklySummaryError) {
        guard summary.visitsThisWeek >= 0 else {
            throw .invalidData
        }

        if let activityMETMinutes = summary.activityMETMinutes,
           !activityMETMinutes.isFinite || activityMETMinutes < 0
        {
            throw .invalidData
        }

        if let lastWorkoutAt = summary.lastWorkoutAt,
           !lastWorkoutAt.timeIntervalSinceReferenceDate.isFinite
        {
            throw .invalidData
        }

        let object: [String: Any] = [
            "activity_met_minutes": summary.activityMETMinutes ?? NSNull(),
            "last_workout_at": summary.lastWorkoutAt.map(Self.formatDate) ?? NSNull(),
            "today_completed": summary.todayCompleted,
            "visits_this_week": summary.visitsThisWeek
        ]
        guard let canonicalJSON = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else {
            throw .invalidData
        }

        visitsThisWeek = summary.visitsThisWeek
        activityMETMinutes = summary.activityMETMinutes
        lastWorkoutAt = summary.lastWorkoutAt
        todayCompleted = summary.todayCompleted
        self.canonicalJSON = canonicalJSON
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Application use case for the provider-neutral `get_member_weekly_summary`
/// tool contract.
public struct GetMemberWeeklySummaryUseCase: Sendable {
    private let repository: any MemberRepository

    public init(repository: any MemberRepository) {
        self.repository = repository
    }

    /// Loads only the weekly summary for the exact requested member ID.
    public func execute(for memberID: MemberID) async throws -> MemberWeeklySummaryToolResult {
        let summary: ExerciseSummary

        do {
            try Task.checkCancellation()
            summary = try await repository.weeklySummary(for: memberID)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw GetMemberWeeklySummaryError.repositoryUnavailable
        }

        do {
            try Task.checkCancellation()
            let result = try MemberWeeklySummaryToolResult(summary: summary)
            try Task.checkCancellation()
            return result
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}
