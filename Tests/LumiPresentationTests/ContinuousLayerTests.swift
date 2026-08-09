import Testing
import Foundation
import LumiDomain
@testable import LumiPresentation

private let mapper = AvatarStateMapper()
private func ~= (lhs: Double, rhs: Double) -> Bool { abs(lhs - rhs) < 0.001 }

// MARK: - 眨眼

@Test("眨眼在排程的高峰時間點讓眼睛閉合到 0，其餘時間維持 base 值")
func blinkReachesZeroAtScheduledTimeAndRestsBetweenBlinks() {
    var rng = SeededGenerator(seed: 1)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.idle)

    let peak = schedule.starts[0] + BlinkSchedule.closeDuration
    let atPeak = ContinuousLayer.apply(to: base, at: peak, schedule: schedule, reducedMotion: false)
    #expect(atPeak.eyeOpenAmount < 0.01)

    // 兩次眨眼中間（第一次眨眼開始前一秒，一定還沒眨）：維持 base 的開眼量。
    let between = schedule.starts[0] - 1.0
    let atRest = ContinuousLayer.apply(to: base, at: between, schedule: schedule, reducedMotion: false)
    #expect(atRest.eyeOpenAmount ~= base.eyeOpenAmount)
}

@Test("眨眼間隔在 2–6 秒之間變動，同一個 seed 可重現")
func blinkIntervalsAreVariableAndReproducibleForSameSeed() {
    var rngA = SeededGenerator(seed: 42)
    var rngB = SeededGenerator(seed: 42)
    let scheduleA = BlinkSchedule(horizon: 120, using: &rngA)
    let scheduleB = BlinkSchedule(horizon: 120, using: &rngB)

    #expect(scheduleA.starts == scheduleB.starts)
    #expect(scheduleA.starts.count > 5)

    let intervals = zip(scheduleA.starts, scheduleA.starts.dropFirst()).map { $1 - $0 }
    #expect(intervals.allSatisfy { (2.0 ... 6.0).contains($0) })
    // 不是固定間隔——四捨五入到 0.01 秒後仍應該有不只一種數值。
    #expect(Set(intervals.map { ($0 * 100).rounded() }).count > 1)
}

@Test("不同 seed 產生不同的眨眼時間表")
func differentSeedsProduceDifferentSchedules() {
    var rngA = SeededGenerator(seed: 1)
    var rngB = SeededGenerator(seed: 2)
    let scheduleA = BlinkSchedule(horizon: 60, using: &rngA)
    let scheduleB = BlinkSchedule(horizon: 60, using: &rngB)
    #expect(scheduleA.starts != scheduleB.starts)
}

// MARK: - 微眼動

@Test("微眼動疊加在 base 的瞳孔位移上，幅度不超過 ±0.05（§5.2）")
func microSaccadesAreAdditiveAndBounded() {
    var rng = SeededGenerator(seed: 7)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.thinking) // 有非零的 base pupilOffset

    for i in stride(from: 0, through: 200, by: 1) {
        let t = Double(i) * 0.37
        let result = ContinuousLayer.apply(to: base, at: t, schedule: schedule, reducedMotion: false)
        let dx = result.pupilOffset.x - base.pupilOffset.x
        let dy = result.pupilOffset.y - base.pupilOffset.y
        #expect(abs(dx) <= 0.05 + 0.0001)
        #expect(abs(dy) <= 0.05 + 0.0001)
    }
}

@Test("微眼動是合成向量長度受限於 ±0.05，不是 X／Y 各自獨立到 0.05（對角線不能超標）")
func microSaccadeCombinedMagnitudeStaysWithinBound() {
    var rng = SeededGenerator(seed: 7)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.thinking)

    for i in stride(from: 0, through: 400, by: 1) {
        let t = Double(i) * 0.13
        let result = ContinuousLayer.apply(to: base, at: t, schedule: schedule, reducedMotion: false)
        let dx = result.pupilOffset.x - base.pupilOffset.x
        let dy = result.pupilOffset.y - base.pupilOffset.y
        let magnitude = (dx * dx + dy * dy).squareRoot()
        #expect(magnitude <= 0.05 + 0.0001)
    }
}

@Test("offline（sleepy 眼皮）不套用微眼動——休息狀態的瞳孔不該還在抖動")
func microSaccadesAreSuppressedForSleepyEyelid() {
    var rng = SeededGenerator(seed: 7)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.offline)
    #expect(base.eyelidStyle == .sleepy)

    for i in stride(from: 0, through: 100, by: 1) {
        let t = Double(i) * 0.31
        let result = ContinuousLayer.apply(to: base, at: t, schedule: schedule, reducedMotion: false)
        #expect(result.pupilOffset == base.pupilOffset)
    }
}

@Test("只有 offline 用 sleepy 眼皮——微眼動『sleepy 就關掉』的判準耦合在這個事實上，這條測試把它釘住")
func onlyOfflineUsesSleepyEyelid() {
    let sleepyStates = AssistantState.baselineCases.filter { mapper.map($0).eyelidStyle == .sleepy }
    #expect(sleepyStates == [.offline])
}

@Test("微眼動不會用中心蓋掉 confused 自己刻意的視線位移")
func microSaccadesDoNotRecenterConfusedGaze() {
    var rng = SeededGenerator(seed: 13)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.confused)

    for i in stride(from: 0, through: 50, by: 1) {
        let t = Double(i) * 0.6
        let result = ContinuousLayer.apply(to: base, at: t, schedule: schedule, reducedMotion: false)
        // confused 的 pupilOffset.x 是 0.25；疊加 ±0.05 微眼動後不可能被拉回 0 或變號。
        #expect(result.pupilOffset.x > 0)
    }
}

// MARK: - 高光呼吸

@Test("高光呼吸的『峰對峰』振幅小於狀態間 highlightIntensity 的最小差距（§4.3：呼吸低於主狀態變化）")
func highlightBreathingPeakToPeakIsSmallerThanSmallestStateGap() {
    var rng = SeededGenerator(seed: 3)
    let schedule = BlinkSchedule(using: &rng)
    let idle = mapper.map(.idle)

    // 規格比較的是「呼吸的擺動」對「狀態間最小差距」，不是對隨便挑兩個狀態的差距
    // ——用基準表本身的最小非零差距（目前是 idle 0.70 對 listening 0.75 = 0.05），
    // 而不是硬編 0.05，這樣基準表以後改了，這條測試還是量對的東西。
    let allHighlightIntensities = AssistantState.baselineCases.map { mapper.map($0).highlightIntensity }
    var minStateGap = Double.infinity
    for i in 0 ..< allHighlightIntensities.count {
        for j in (i + 1) ..< allHighlightIntensities.count {
            let gap = abs(allHighlightIntensities[i] - allHighlightIntensities[j])
            if gap > 0.0001 { minStateGap = min(minStateGap, gap) }
        }
    }

    // 掃超過一個完整呼吸週期，抓到真正的峰值與谷值——量「max - min」（峰對峰），
    // 不是「離 base 的單邊偏移」。單邊偏移只有峰對峰的一半，之前就是量錯這個
    // 才讓 0.03 的振幅（峰對峰其實是 0.06）騙過了測試。
    var minValue = Double.infinity
    var maxValue = -Double.infinity
    let steps = 400
    let window = ContinuousLayer.breathingPeriod * 1.5
    for i in 0 ... steps {
        let t = window * Double(i) / Double(steps)
        let result = ContinuousLayer.apply(to: idle, at: t, schedule: schedule, reducedMotion: false)
        minValue = min(minValue, result.highlightIntensity)
        maxValue = max(maxValue, result.highlightIntensity)
    }
    let peakToPeak = maxValue - minValue
    print("measured breathing peak-to-peak = \(peakToPeak), smallest state gap = \(minStateGap)")

    #expect(peakToPeak > 0) // 呼吸真的在動
    #expect(peakToPeak < minStateGap)
}

// MARK: - 不機械式同步

@Test("眨眼峰值與呼吸相位不會反覆對齊（§4.3：週期不可與固定眨眼同步）")
func blinkAndBreathingDoNotRepeatedlyCoincide() {
    var rng = SeededGenerator(seed: 11)
    let schedule = BlinkSchedule(horizon: 600, using: &rng)

    // 若同步，每次眨眼峰值時呼吸相位（sin 值）會集中在同一個點附近，標準差趨近 0。
    let phases = schedule.starts.map { start in
        sin(2 * Double.pi * (start + BlinkSchedule.closeDuration) / ContinuousLayer.breathingPeriod)
    }
    let mean = phases.reduce(0, +) / Double(phases.count)
    var sumSquaredDeviation = 0.0
    for phase in phases {
        let deviation = phase - mean
        sumSquaredDeviation += deviation * deviation
    }
    let variance = sumSquaredDeviation / Double(phases.count)
    #expect(variance.squareRoot() > 0.3)
}

// MARK: - Reduced Motion（Continuous 層本身：眨眼曲線）

@Test("減少動態效果下眨眼保留，但不是全閉、也不是線性跳動")
func reducedMotionBlinkIsGentleNotJumpy() {
    var rng = SeededGenerator(seed: 5)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.idle)
    let peak = schedule.starts[0] + BlinkSchedule.closeDuration

    let normal = ContinuousLayer.apply(to: base, at: peak, schedule: schedule, reducedMotion: false)
    let gentle = ContinuousLayer.apply(to: base, at: peak, schedule: schedule, reducedMotion: true)

    #expect(normal.eyeOpenAmount < 0.01) // 一般情況下眨眼會真的閉到底
    #expect(gentle.eyeOpenAmount > normal.eyeOpenAmount) // 減少動態效果不會全閉
    #expect(gentle.eyeOpenAmount < base.eyeOpenAmount) // 但仍看得出正在眨眼
}
