import Foundation
import OSLog

/// Compares sustained near-end microphone evidence with the residual echo
/// learned while Realtime output is already playing.
///
/// Provider VAD remains the first speech-like signal. This policy is the
/// second, local guard that prevents a loud speaker echo from becoming an
/// interruption merely because it crossed the provider's VAD threshold.
struct OpenAIRealtimeBargeInLevelPolicy: Sendable {
    let minimumBaselineSamples: Int
    let minimumCandidateSamples: Int
    let requiredLevelRatio: Double
    let requiredLevelDelta: Double

    func confirmsInterruption(
        baselineLevels: [Double],
        candidateLevels: [Double]
    ) -> Bool {
        guard baselineLevels.count >= minimumBaselineSamples,
              candidateLevels.count >= minimumCandidateSamples,
              let baseline = median(of: baselineLevels),
              let candidate = median(of: candidateLevels)
        else {
            return false
        }

        let requiredLevel = max(
            baseline * requiredLevelRatio,
            baseline + requiredLevelDelta
        )
        return candidate >= requiredLevel
    }

    private func median(of levels: [Double]) -> Double? {
        guard levels.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) }) else {
            return nil
        }
        let sorted = levels.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

protocol OpenAIRealtimeMicrophoneLevelSource: Sendable {
    /// Normalized WebRTC microphone level in the inclusive `0...1` range.
    /// No audio samples or transcripts cross this boundary.
    func microphoneLevel() async -> Double?
}

protocol OpenAIRealtimeBargeInSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

private struct ContinuousBargeInSleeper: OpenAIRealtimeBargeInSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

protocol OpenAIRealtimeBargeInDetecting: Sendable {
    func assistantOutputStarted() async
    func assistantOutputEnded() async
    func confirmInterruption() async -> Bool
    func rejectedInputEnded() async
}

/// Maintains the most recent post-AEC microphone levels while assistant audio
/// is playing, then compares a sustained candidate against that local echo
/// baseline. The pilot uses three samples at 80 ms intervals in each phase:
/// short noise cannot interrupt, startup transients age out, and unavailable
/// or invalid statistics fail closed.
actor OpenAIRealtimeAdaptiveBargeInDetector: OpenAIRealtimeBargeInDetecting {
    private static let diagnostics = Logger(
        subsystem: "com.curves.lumi",
        category: "realtime-barge-in"
    )

    private enum PilotTuning {
        static let sampleInterval = Duration.milliseconds(80)
        static let sampleCount = 3
        static let policy = OpenAIRealtimeBargeInLevelPolicy(
            minimumBaselineSamples: sampleCount,
            minimumCandidateSamples: sampleCount,
            requiredLevelRatio: 1.8,
            requiredLevelDelta: 0.02
        )
    }

    private let levelSource: any OpenAIRealtimeMicrophoneLevelSource
    private let sleeper: any OpenAIRealtimeBargeInSleeping
    private var outputGeneration: UInt64 = 0
    private var outputIsActive = false
    private var baselineLevels: [Double] = []
    private var baselineTask: Task<Void, Never>?

    init(
        levelSource: any OpenAIRealtimeMicrophoneLevelSource,
        sleeper: any OpenAIRealtimeBargeInSleeping = ContinuousBargeInSleeper()
    ) {
        self.levelSource = levelSource
        self.sleeper = sleeper
    }

    func assistantOutputStarted() {
        Self.diagnostics.notice("detector output-started")
        outputGeneration &+= 1
        outputIsActive = true
        baselineLevels.removeAll(keepingCapacity: true)
        startBaselineSampling(generation: outputGeneration)
    }

    func assistantOutputEnded() {
        Self.diagnostics.notice("detector output-ended")
        outputGeneration &+= 1
        outputIsActive = false
        baselineTask?.cancel()
        baselineTask = nil
        baselineLevels.removeAll(keepingCapacity: true)
    }

    func confirmInterruption() async -> Bool {
        guard outputIsActive else {
            Self.diagnostics.notice("decision rejected reason=output-inactive")
            return false
        }
        let acceptedGeneration = outputGeneration
        baselineTask?.cancel()
        baselineTask = nil
        let baseline = baselineLevels
        var candidate: [Double] = []
        candidate.reserveCapacity(PilotTuning.sampleCount)

        do {
            for _ in 0 ..< PilotTuning.sampleCount {
                try await sleeper.sleep(for: PilotTuning.sampleInterval)
                try Task.checkCancellation()
                guard outputIsActive,
                      outputGeneration == acceptedGeneration else {
                    return false
                }
                if let level = await levelSource.microphoneLevel() {
                    candidate.append(level)
                } else {
                    Self.diagnostics.notice("candidate level=unavailable")
                }
            }
        } catch {
            return false
        }

        guard outputIsActive,
              outputGeneration == acceptedGeneration else {
            return false
        }
        let confirmed = PilotTuning.policy.confirmsInterruption(
            baselineLevels: baseline,
            candidateLevels: candidate
        )
        Self.diagnostics.notice(
            "decision confirmed=\(confirmed) baseline-count=\(baseline.count) candidate-count=\(candidate.count)"
        )
        return confirmed
    }

    func rejectedInputEnded() {
        guard outputIsActive else { return }
        baselineLevels.removeAll(keepingCapacity: true)
        startBaselineSampling(generation: outputGeneration)
    }

    private func startBaselineSampling(generation acceptedGeneration: UInt64) {
        baselineTask?.cancel()
        let levelSource = levelSource
        let sleeper = sleeper
        baselineTask = Task { [weak self] in
            while !Task.isCancelled {
                guard !Task.isCancelled else { return }
                if let level = await levelSource.microphoneLevel() {
                    guard let self else { return }
                    await self.recordBaseline(
                        level,
                        generation: acceptedGeneration
                    )
                }
                do {
                    try await sleeper.sleep(for: PilotTuning.sampleInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func recordBaseline(_ level: Double, generation: UInt64) {
        guard outputIsActive, outputGeneration == generation else { return }
        baselineLevels.append(level)
        if baselineLevels.count > PilotTuning.sampleCount {
            baselineLevels.removeFirst(
                baselineLevels.count - PilotTuning.sampleCount
            )
        }
    }
}
