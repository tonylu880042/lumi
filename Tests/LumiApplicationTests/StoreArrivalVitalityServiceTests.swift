import Testing
import LumiDomain
@testable import LumiApplication

@Suite("Store arrival vitality service")
struct StoreArrivalVitalityServiceTests {
    @Test("records one arrival until a confirmed absence rearms the latch")
    func recordsOneArrivalPerPresencePeriod() async {
        let service = StoreArrivalVitalityService()

        let first = await service.recordArrival(at: .seconds(0))
        let duplicate = await service.recordArrival(at: .seconds(1))
        #expect(first.didRecordArrival)
        #expect(duplicate.didRecordArrival == false)
        #expect(duplicate.vitality == .calm)

        _ = await service.markDeparture(at: .seconds(4))
        let next = await service.recordArrival(at: .seconds(5))
        #expect(next.didRecordArrival)
    }

    @Test("unavailable observations never count as absence or arrivals")
    func unavailableObservationsDoNotRearm() async {
        let service = StoreArrivalVitalityService()

        _ = await service.recordArrival(at: .seconds(0))
        let unavailable = await service.observe(.unavailable, at: .seconds(1))

        #expect(unavailable.didRecordArrival == false)
        let duplicate = await service.recordArrival(at: .seconds(4))
        #expect(duplicate.didRecordArrival == false)

        _ = await service.observe(.absent, at: .seconds(5))
        _ = await service.observe(.absent, at: .seconds(7.9))
        let stillDuplicate = await service.recordArrival(at: .seconds(8))
        #expect(stillDuplicate.didRecordArrival == false)
    }

    @Test("snapshot reflects rolling-window expiry while the service is idle")
    func snapshotExpiresArrivals() async {
        let service = StoreArrivalVitalityService()
        for second in [0, 4, 8, 12, 16, 20] {
            _ = await service.recordArrival(at: .seconds(second))
            if second < 20 {
                _ = await service.markDeparture(at: .seconds(second + 3))
            }
        }

        #expect(await service.snapshot(at: .seconds(600)) == .happy)
        #expect(await service.snapshot(at: .seconds(612)) == .calm)
    }
}
