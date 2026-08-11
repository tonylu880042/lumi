import Foundation

/// A member's exercise activity summary.
public struct ExerciseSummary: Equatable, Sendable {
    /// The number of visits during the current week.
    public let visitsThisWeek: Int

    /// The total activity volume measured in MET-minutes, when available.
    public let activityMETMinutes: Double?

    /// The time of the most recent workout, when available.
    public let lastWorkoutAt: Date?

    /// Whether today's exercise is completed.
    public let todayCompleted: Bool

    /// Creates an exercise activity summary.
    public init(
        visitsThisWeek: Int,
        activityMETMinutes: Double?,
        lastWorkoutAt: Date?,
        todayCompleted: Bool
    ) {
        self.visitsThisWeek = visitsThisWeek
        self.activityMETMinutes = activityMETMinutes
        self.lastWorkoutAt = lastWorkoutAt
        self.todayCompleted = todayCompleted
    }
}
