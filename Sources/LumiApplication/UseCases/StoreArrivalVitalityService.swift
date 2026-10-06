import LumiDomain

/// Monotonic time used by the arrival vitality service. Tests can provide a
/// deterministic clock without importing Foundation or any platform clock.
public protocol StoreArrivalVitalityClock: Sendable {
    func now() -> Duration
}

public struct ContinuousStoreArrivalVitalityClock:
    StoreArrivalVitalityClock,
    Sendable
{
    private let origin = ContinuousClock.now

    public init() {}

    public func now() -> Duration {
        origin.duration(to: .now)
    }
}

/// The privacy-safe result of one arrival observation. It contains only the
/// resulting vitality and whether the observation opened a new arrival event.
public struct StoreArrivalVitalityUpdate: Equatable, Sendable {
    public let vitality: StoreArrivalVitality
    public let didRecordArrival: Bool

    public init(vitality: StoreArrivalVitality, didRecordArrival: Bool) {
        self.vitality = vitality
        self.didRecordArrival = didRecordArrival
    }
}

/// Application use case that turns the monitor's non-identifying observations
/// into rolling arrival vitality. The same instance can be shared by the App
/// avatar model and a voice adapter's local greeting provider.
public actor StoreArrivalVitalityService {
    public static let defaultAbsenceDuration: Duration = .seconds(3)

    private let clock: any StoreArrivalVitalityClock
    private var policy: StoreArrivalVitalityPolicy
    private var deduplicator: StoreArrivalObservationDeduplicator

    public init(
        window: Duration = StoreArrivalVitalityPolicy.defaultWindow,
        absenceDuration: Duration = StoreArrivalVitalityService.defaultAbsenceDuration,
        clock: any StoreArrivalVitalityClock =
            ContinuousStoreArrivalVitalityClock()
    ) {
        let normalizedAbsenceDuration = max(.zero, absenceDuration)
        self.clock = clock
        self.policy = StoreArrivalVitalityPolicy(window: window)
        self.deduplicator = StoreArrivalObservationDeduplicator(
            absenceDuration: normalizedAbsenceDuration
        )
    }

    /// Applies a timestamped, provider-neutral observation.
    @discardableResult
    public func observe(
        _ observation: StoreArrivalObservation,
        at time: Duration
    ) -> StoreArrivalVitalityUpdate {
        let didRecordArrival = deduplicator.observe(observation, at: time)
        if didRecordArrival {
            policy.recordArrival(at: time)
        }
        return StoreArrivalVitalityUpdate(
            vitality: policy.snapshot(now: time),
            didRecordArrival: didRecordArrival
        )
    }

    /// Records the first usable face observed at the current monotonic time.
    @discardableResult
    public func recordArrival() -> StoreArrivalVitalityUpdate {
        recordArrival(at: clock.now())
    }

    /// Records a first usable face at an injected timestamp.
    @discardableResult
    public func recordArrival(at time: Duration) -> StoreArrivalVitalityUpdate {
        observe(.present, at: time)
    }

    /// Marks a monitor-confirmed continuous absence. The monitor has already
    /// observed the configured interval, so this method advances the pure
    /// deduplicator through that interval and rearms it for the next arrival.
    @discardableResult
    public func markDeparture() -> StoreArrivalVitality {
        markDeparture(at: clock.now())
    }

    /// Timestamped form of `markDeparture` used by deterministic tests.
    @discardableResult
    public func markDeparture(at time: Duration) -> StoreArrivalVitality {
        // PilotVisitorPresenceMonitor owns camera sampling and calls this only
        // after it has confirmed the configured continuous absence interval.
        // The deduplicator remains the single arrival latch owner; this direct
        // rearm avoids fabricated observations that could move time backwards.
        deduplicator.rearmAfterConfirmedAbsence()
        return policy.snapshot(now: time)
    }

    /// Returns the current rolling vitality without adding an event.
    public func snapshot() -> StoreArrivalVitality {
        policy.snapshot(now: clock.now())
    }

    /// Returns the rolling vitality at a deterministic timestamp.
    public func snapshot(at time: Duration) -> StoreArrivalVitality {
        policy.snapshot(now: time)
    }

    public func currentVitality() -> StoreArrivalVitality {
        snapshot()
    }
}
