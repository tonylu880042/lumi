import LumiApplication
import LumiDomain
import LumiInfrastructure
import Testing

@Suite("Mock hardware control")
struct MockHardwareControlPortTests {
    @Test("records a rotation target and completes only after explicit arrival")
    func rotationWaitsForArrival() async throws {
        let hardware = MockHardwareControlPort()
        let target = try RotationAngle(degrees: 30)
        let outcome = RotationOutcome()

        let rotation = Task {
            do {
                try await hardware.rotate(to: target)
                await outcome.markCompleted()
            } catch {
                await outcome.markFailed()
            }
        }

        for _ in 0..<32 {
            if await hardware.rotationTargets == [target] { break }
            await Task.yield()
        }

        #expect(await hardware.rotationTargets == [target])
        #expect(await outcome.didComplete == false)
        #expect(await outcome.didFail == false)

        await hardware.completeRotation()
        await rotation.value
        #expect(await outcome.didComplete)
        #expect(await outcome.didFail == false)
    }

    @Test("rejects a second rotation without replacing the first continuation")
    func concurrentRotationIsRejected() async throws {
        let hardware = MockHardwareControlPort()
        let firstTarget = try RotationAngle(degrees: -30)
        let secondTarget = try RotationAngle(degrees: 45)

        let first = Task {
            try await hardware.rotate(to: firstTarget)
        }

        for _ in 0..<32 {
            if await hardware.rotationTargets == [firstTarget] { break }
            await Task.yield()
        }

        await #expect(throws: MockHardwareControlError.rotationInProgress) {
            try await hardware.rotate(to: secondTarget)
        }
        #expect(await hardware.rotationTargets == [firstTarget])

        await hardware.completeRotation()
        try await first.value
    }

    @Test("cancellation of a rejected request cannot cancel the active rotation")
    func rejectedCancellationDoesNotTouchActiveRotation() async throws {
        let hardware = MockHardwareControlPort()
        let firstTarget = try RotationAngle(degrees: -20)
        let rejectedTarget = try RotationAngle(degrees: 20)

        let first = Task {
            try await hardware.rotate(to: firstTarget)
        }
        for _ in 0..<32 {
            if await hardware.rotationTargets == [firstTarget] { break }
            await Task.yield()
        }

        let rejected = Task { () -> Bool in
            do {
                try await hardware.rotate(to: rejectedTarget)
                return true
            } catch {
                return false
            }
        }
        rejected.cancel()
        #expect(await rejected.value == false)

        for _ in 0..<32 {
            await Task.yield()
        }

        #expect(await hardware.rotationTargets == [firstTarget])
        await hardware.completeRotation()
        try await first.value
    }

    @Test("cancellation releases a pending rotation for the next command")
    func cancellationReleasesPendingRotation() async throws {
        let hardware = MockHardwareControlPort()
        let canceledTarget = try RotationAngle(degrees: -15)
        let nextTarget = try RotationAngle(degrees: 15)

        let canceled = Task {
            try await hardware.rotate(to: canceledTarget)
        }

        for _ in 0..<32 {
            if await hardware.rotationTargets == [canceledTarget] { break }
            await Task.yield()
        }

        canceled.cancel()
        await #expect(throws: CancellationError.self) {
            try await canceled.value
        }

        let next = Task {
            try await hardware.rotate(to: nextTarget)
        }
        for _ in 0..<32 {
            if await hardware.rotationTargets == [canceledTarget, nextTarget] { break }
            await Task.yield()
        }

        #expect(await hardware.rotationTargets == [canceledTarget, nextTarget])
        await hardware.completeRotation()
        try await next.value
    }

    @Test("stop fails an active rotation and records the stop")
    func stopCancelsActiveRotation() async throws {
        let hardware = MockHardwareControlPort()
        let target = try RotationAngle(degrees: 10)

        let rotation = Task {
            try await hardware.rotate(to: target)
        }
        for _ in 0..<32 {
            if await hardware.rotationTargets == [target] { break }
            await Task.yield()
        }

        await hardware.stop()
        await #expect(throws: CancellationError.self) {
            try await rotation.value
        }
        #expect(await hardware.stopCallCount == 1)

        await hardware.completeRotation()
    }

    @Test("returnHome records the requested action")
    func returnHomeIsObservable() async throws {
        let hardware = MockHardwareControlPort()
        let request = Task {
            try await hardware.returnHome()
        }

        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        #expect(await hardware.returnHomeCallCount == 1)
        await hardware.completeReturnHome()
        try await request.value
    }

    @Test("returnHome waits for explicit confirmed home arrival")
    func returnHomeWaitsForArrival() async throws {
        let hardware = MockHardwareControlPort()
        let request = Task {
            try await hardware.returnHome()
        }

        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        #expect(await hardware.returnHomeCallCount == 1)
        await Task.yield()
        #expect(await hardware.hasPendingReturnHome)

        await hardware.completeReturnHome()
        try await request.value
        #expect(await hardware.hasPendingReturnHome == false)
    }

    @Test("returnHome propagates an explicit home-arrival failure")
    func returnHomeFailureIsPropagated() async throws {
        let hardware = MockHardwareControlPort()
        let request = Task {
            try await hardware.returnHome()
        }

        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        await hardware.failPendingReturnHome(with: HomeFailure.injected)

        await #expect(throws: HomeFailure.injected) {
            try await request.value
        }
        #expect(await hardware.hasPendingReturnHome == false)
    }

    @Test("cancelling returnHome releases it and permits a retry")
    func cancellationReleasesPendingReturnHome() async throws {
        let hardware = MockHardwareControlPort()
        let canceled = Task {
            try await hardware.returnHome()
        }

        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        canceled.cancel()
        await #expect(throws: CancellationError.self) {
            try await canceled.value
        }
        #expect(await hardware.hasPendingReturnHome == false)

        let retry = Task {
            try await hardware.returnHome()
        }
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        await hardware.completeReturnHome()
        try await retry.value
        #expect(await hardware.returnHomeCallCount == 2)
    }

    @Test("late returnHome completion after cancellation cannot resolve a retry")
    func staleReturnHomeCompletionIsIgnored() async throws {
        let hardware = MockHardwareControlPort()
        let canceled = Task {
            try await hardware.returnHome()
        }

        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        canceled.cancel()
        await #expect(throws: CancellationError.self) {
            try await canceled.value
        }

        await hardware.completeReturnHome()
        #expect(await hardware.hasPendingReturnHome == false)

        let retry = Task {
            try await hardware.returnHome()
        }
        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        await Task.yield()
        #expect(await hardware.hasPendingReturnHome)

        await hardware.completeReturnHome()
        try await retry.value
    }

    @Test("duplicate returnHome is rejected without resolving the first request")
    func duplicateReturnHomeIsRejected() async throws {
        let hardware = MockHardwareControlPort()
        let first = Task {
            try await hardware.returnHome()
        }

        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        await #expect(throws: MockHardwareControlError.returnHomeInProgress) {
            try await hardware.returnHome()
        }
        #expect(await hardware.returnHomeCallCount == 2)
        #expect(await hardware.hasPendingReturnHome)

        await hardware.completeReturnHome()
        try await first.value
    }

    @Test("cancellation of a rejected returnHome cannot cancel the active request")
    func rejectedReturnHomeCancellationDoesNotTouchActiveRequest() async throws {
        let hardware = MockHardwareControlPort()
        let active = Task {
            try await hardware.returnHome()
        }

        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        let rejected = Task {
            try await hardware.returnHome()
        }
        #expect(await waitUntil { await hardware.returnHomeCallCount == 2 })
        rejected.cancel()

        await #expect(throws: MockHardwareControlError.returnHomeInProgress) {
            try await rejected.value
        }
        #expect(await hardware.hasPendingReturnHome)

        await hardware.completeReturnHome()
        try await active.value
    }

    @Test("returnHome is rejected while a rotation is pending")
    func returnHomeDoesNotReplacePendingRotation() async throws {
        let hardware = MockHardwareControlPort()
        let target = try RotationAngle(degrees: 30)
        let rotation = Task {
            try await hardware.rotate(to: target)
        }

        #expect(await waitUntil { await hardware.rotationTargets == [target] })
        await #expect(throws: MockHardwareControlError.rotationInProgress) {
            try await hardware.returnHome()
        }
        #expect(await hardware.returnHomeCallCount == 1)
        #expect(await hardware.rotationTargets == [target])

        await hardware.completeRotation()
        try await rotation.value
    }

    @Test("rotation is rejected while returnHome is pending")
    func rotationDoesNotReplacePendingReturnHome() async throws {
        let hardware = MockHardwareControlPort()
        let home = Task {
            try await hardware.returnHome()
        }
        let target = try RotationAngle(degrees: -30)

        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        await #expect(throws: MockHardwareControlError.returnHomeInProgress) {
            try await hardware.rotate(to: target)
        }
        #expect(await hardware.rotationTargets.isEmpty)
        #expect(await hardware.hasPendingReturnHome)

        await hardware.completeReturnHome()
        try await home.value
    }

    @Test("stop cancels a pending returnHome and remains safe when repeated or idle")
    func stopCancelsPendingReturnHome() async throws {
        let hardware = MockHardwareControlPort()
        let home = Task {
            try await hardware.returnHome()
        }

        #expect(await waitUntil { await hardware.hasPendingReturnHome })
        await hardware.stop()
        await #expect(throws: CancellationError.self) {
            try await home.value
        }
        #expect(await hardware.stopCallCount == 1)
        #expect(await hardware.hasPendingReturnHome == false)

        await hardware.completeReturnHome()
        await hardware.stop()
        #expect(await hardware.stopCallCount == 2)
    }
}

private actor RotationOutcome {
    private(set) var didComplete = false
    private(set) var didFail = false

    func markCompleted() {
        didComplete = true
    }

    func markFailed() {
        didFail = true
    }
}

private enum HomeFailure: Error, Equatable, Sendable {
    case injected
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< 64 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
