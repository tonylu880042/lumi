import Foundation

public enum StoreArrivalObservation: Equatable, Sendable {
    case present, absent, unavailable
}

public struct StoreArrivalObservationDeduplicator: Sendable {
    public let absenceDuration: Duration
    private var armed = true
    private var absenceStartedAt: Duration?

    public init(absenceDuration: Duration = .seconds(3)) {
        self.absenceDuration = absenceDuration
    }

    public mutating func observe(_ observation: StoreArrivalObservation, at time: Duration) -> Bool {
        switch observation {
        case .present:
            absenceStartedAt = nil
            guard armed else { return false }
            armed = false
            return true
        case .absent:
            guard !armed else { return false }
            if absenceStartedAt == nil { absenceStartedAt = time }
            if let start = absenceStartedAt, time - start >= absenceDuration {
                armed = true
                absenceStartedAt = nil
            }
            return false
        case .unavailable:
            absenceStartedAt = nil
            return false
        }
    }

    /// Rearms after Infrastructure has already confirmed the complete absence
    /// interval. This keeps the monitor's timing result from being replayed
    /// through synthetic, potentially out-of-order observations.
    public mutating func rearmAfterConfirmedAbsence() {
        armed = true
        absenceStartedAt = nil
    }
}
