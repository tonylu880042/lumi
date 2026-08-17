import Foundation

/// The coarse weekly visit band used as non-identifying conversation context.
public enum VisitFrequencyBand: String, Equatable, Sendable {
    case none
    case oneToTwo
    case threeOrMore

    public static func from(visitCount: Int) -> Self {
        switch visitCount {
        case ...0: .none
        case 1...2: .oneToTwo
        default: .threeOrMore
        }
    }
}

/// A visit summary that can safely be mapped to a conversation context.
public struct MemberVisitSummary: Equatable, Sendable {
    public let visitCount: Int
    public let lastArrivalAt: Date?

    public var frequencyBand: VisitFrequencyBand {
        VisitFrequencyBand.from(visitCount: visitCount)
    }

    public init(visitCount: Int, lastArrivalAt: Date?) {
        self.visitCount = max(0, visitCount)
        self.lastArrivalAt = lastArrivalAt
    }
}
