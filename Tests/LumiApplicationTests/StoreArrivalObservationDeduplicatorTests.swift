import Testing
@testable import LumiApplication

@Suite("Store arrival observation deduplicator")
struct StoreArrivalObservationDeduplicatorTests {
    @Test("one continuous presence emits once and three seconds absent rearms")
    func deduplicatesPresence() {
        var d = StoreArrivalObservationDeduplicator()
        #expect(d.observe(.present, at: .seconds(0)) == true)
        #expect(d.observe(.present, at: .seconds(1)) == false)
        #expect(d.observe(.absent, at: .seconds(2)) == false)
        #expect(d.observe(.absent, at: .seconds(4.9)) == false)
        #expect(d.observe(.absent, at: .seconds(5)) == false)
        #expect(d.observe(.present, at: .seconds(6)) == true)
    }

    @Test("unavailable observation clears absence continuity and neither emits nor rearms")
    func unavailableDoesNotRearm() {
        var d = StoreArrivalObservationDeduplicator()
        #expect(d.observe(.present, at: .seconds(0)) == true)
        #expect(d.observe(.absent, at: .seconds(1)) == false)
        #expect(d.observe(.unavailable, at: .seconds(2)) == false)
        #expect(d.observe(.absent, at: .seconds(4)) == false)
        #expect(d.observe(.absent, at: .seconds(6.9)) == false)
        #expect(d.observe(.absent, at: .seconds(7)) == false)
        #expect(d.observe(.present, at: .seconds(8)) == true)
    }

}
