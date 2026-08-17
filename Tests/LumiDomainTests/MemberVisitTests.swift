import Foundation
import Testing
import LumiDomain

@Test("visit frequency uses the approved weekly bands")
func visitFrequencyUsesApprovedBands() {
    #expect(VisitFrequencyBand.from(visitCount: 0) == .none)
    #expect(VisitFrequencyBand.from(visitCount: 1) == .oneToTwo)
    #expect(VisitFrequencyBand.from(visitCount: 2) == .oneToTwo)
    #expect(VisitFrequencyBand.from(visitCount: 3) == .threeOrMore)
    #expect(VisitFrequencyBand.from(visitCount: 99) == .threeOrMore)
}

@Test("visit summary preserves count, last arrival, and derived band")
func visitSummaryPreservesValues() {
    let lastArrival = Date(timeIntervalSince1970: 1_754_464_200)
    let summary = MemberVisitSummary(
        visitCount: 3,
        lastArrivalAt: lastArrival
    )

    #expect(summary.visitCount == 3)
    #expect(summary.lastArrivalAt == lastArrival)
    #expect(summary.frequencyBand == .threeOrMore)
}
