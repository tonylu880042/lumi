import Foundation

public enum StoreArrivalVitality: Equatable, Sendable {
    case calm, happy, excited
}

public struct StoreArrivalVitalityPolicy: Sendable {
    public static let defaultWindow: Duration = .seconds(600)
    private static let maximumEvents = 6
    private let window: Duration
    private var arrivals: [Duration] = []

    public init(window: Duration = Self.defaultWindow) {
        self.window = window
    }

    public mutating func recordArrival(at time: Duration) {
        arrivals.append(time)
        if arrivals.count > Self.maximumEvents {
            arrivals.removeFirst(arrivals.count - Self.maximumEvents)
        }
    }

    public func snapshot(now: Duration) -> StoreArrivalVitality {
        let count = arrivals.reduce(into: 0) { result, arrival in
            let age = now - arrival
            if age >= .zero && age < window { result += 1 }
        }
        switch count {
        case 0...2: return .calm
        case 3...5: return .happy
        default: return .excited
        }
    }
}
