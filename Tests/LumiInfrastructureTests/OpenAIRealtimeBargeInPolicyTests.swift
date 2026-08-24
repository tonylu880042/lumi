@testable import LumiInfrastructure
import Testing

@Suite("OpenAI Realtime controlled barge-in policy")
struct OpenAIRealtimeBargeInPolicyTests {
    @Test("speaker echo that stays near the learned baseline is rejected")
    func rejectsResidualSpeakerEcho() {
        let policy = OpenAIRealtimeBargeInLevelPolicy(
            minimumBaselineSamples: 3,
            minimumCandidateSamples: 3,
            requiredLevelRatio: 1.8,
            requiredLevelDelta: 0.02
        )

        #expect(policy.confirmsInterruption(
            baselineLevels: [0.10, 0.11, 0.12],
            candidateLevels: [0.11, 0.12, 0.13]
        ) == false)
    }

    @Test("sustained near-end speech clearly above echo confirms interruption")
    func confirmsNearEndSpeechAboveEcho() {
        let policy = OpenAIRealtimeBargeInLevelPolicy(
            minimumBaselineSamples: 3,
            minimumCandidateSamples: 3,
            requiredLevelRatio: 1.8,
            requiredLevelDelta: 0.02
        )

        #expect(policy.confirmsInterruption(
            baselineLevels: [0.02, 0.03, 0.04],
            candidateLevels: [0.17, 0.19, 0.18]
        ))
    }

    @Test("missing warmup or sustained evidence fails closed")
    func rejectsInsufficientEvidence() {
        let policy = OpenAIRealtimeBargeInLevelPolicy(
            minimumBaselineSamples: 3,
            minimumCandidateSamples: 3,
            requiredLevelRatio: 1.8,
            requiredLevelDelta: 0.02
        )

        #expect(policy.confirmsInterruption(
            baselineLevels: [0.02, 0.03],
            candidateLevels: [0.20, 0.21, 0.22]
        ) == false)
        #expect(policy.confirmsInterruption(
            baselineLevels: [0.02, 0.03, 0.04],
            candidateLevels: [0.20, 0.21]
        ) == false)
        #expect(policy.confirmsInterruption(
            baselineLevels: [0.02, .nan, 0.04],
            candidateLevels: [0.20, 0.21, 0.22]
        ) == false)
    }

    @Test("adaptive detector samples a completed echo baseline before confirming speech")
    func adaptiveDetectorConfirmsSustainedNearEndSpeech() async {
        let source = ScriptedMicrophoneLevelSource(levels: [
            0.02, 0.03, 0.04,
            0.17, 0.19, 0.18,
        ])
        let sleeper = YieldingCountingBargeInSleeper()
        let detector = OpenAIRealtimeAdaptiveBargeInDetector(
            levelSource: source,
            sleeper: sleeper
        )

        await detector.assistantOutputStarted()
        #expect(await waitUntil { await sleeper.sleepCount >= 3 })

        #expect(await detector.confirmInterruption())
        #expect(await source.requestCount == 6)
    }

    @Test("adaptive detector rejects residual output echo")
    func adaptiveDetectorRejectsResidualEcho() async {
        let source = ScriptedMicrophoneLevelSource(levels: [
            0.10, 0.11, 0.12,
            0.11, 0.12, 0.13,
        ])
        let sleeper = YieldingCountingBargeInSleeper()
        let detector = OpenAIRealtimeAdaptiveBargeInDetector(
            levelSource: source,
            sleeper: sleeper
        )

        await detector.assistantOutputStarted()
        #expect(await waitUntil { await sleeper.sleepCount >= 3 })

        #expect(await detector.confirmInterruption() == false)
        #expect(await source.requestCount == 6)
    }
}

private actor ScriptedMicrophoneLevelSource: OpenAIRealtimeMicrophoneLevelSource {
    private let levels: [Double?]
    private(set) var requestCount = 0

    init(levels: [Double?]) {
        self.levels = levels
    }

    func microphoneLevel() -> Double? {
        defer { requestCount += 1 }
        guard requestCount < levels.count else { return nil }
        return levels[requestCount]
    }
}

private actor YieldingCountingBargeInSleeper: OpenAIRealtimeBargeInSleeping {
    private(set) var sleepCount = 0

    func sleep(for duration: Duration) async throws {
        _ = duration
        try Task.checkCancellation()
        sleepCount += 1
        await Task.yield()
    }
}

private func waitUntil(
    maxAttempts: Int = 200,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< maxAttempts {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
