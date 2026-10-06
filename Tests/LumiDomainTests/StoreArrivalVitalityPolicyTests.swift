import Testing
@testable import LumiDomain

@Suite("Store arrival vitality policy")
struct StoreArrivalVitalityPolicyTests {
    @Test("counts arrivals in the ten minute window")
    func levels() {
        var policy = StoreArrivalVitalityPolicy()
        #expect(policy.snapshot(now: .seconds(0)) == .calm)
        for i in 0..<2 { policy.recordArrival(at: .seconds(i)) }
        #expect(policy.snapshot(now: .seconds(10)) == .calm)
        policy.recordArrival(at: .seconds(2))
        #expect(policy.snapshot(now: .seconds(10)) == .happy)
        policy.recordArrival(at: .seconds(3))
        policy.recordArrival(at: .seconds(4))
        #expect(policy.snapshot(now: .seconds(10)) == .happy)
    }

    @Test("six arrivals cool down as each event crosses the ten minute boundary")
    func excitedAndExpiry() {
        var policy = StoreArrivalVitalityPolicy()
        for i in 0..<6 { policy.recordArrival(at: .seconds(i)) }
        #expect(policy.snapshot(now: .seconds(10)) == .excited)
        #expect(policy.snapshot(now: .seconds(600)) == .happy)
        #expect(policy.snapshot(now: .seconds(603)) == .calm)
        #expect(policy.snapshot(now: .seconds(605)) == .calm)
    }
}
