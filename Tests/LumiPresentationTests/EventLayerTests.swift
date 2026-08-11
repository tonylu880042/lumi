import Testing
import Foundation
@testable import LumiPresentation

private let mapper = AvatarStateMapper()
private let allCommands: [AvatarEventCommand] = [
    .playful,
    .memberRecognized,
    .firstVisit,
    .longTimeNoSee,
    .goalAchieved,
    .weeklyGoalCompleted,
    .error,
]

@Test("沒有 active event 時，Event 層原樣回傳輸入的 state")
func noActiveEventPassesThroughUnchanged() {
    let base = mapper.map(.idle)
    let result = EventLayer.apply(to: base, at: 5.0, active: nil)
    #expect(result == base)
}

@Test("事件在 duration 之外（尚未開始或已經播完）時原樣回傳輸入，不覆蓋 effect", arguments: allCommands)
func eventOutsideDurationPassesThroughUnchanged(kind: AvatarEventCommand) {
    let base = mapper.map(.idle)
    let active = ActiveEvent(kind: kind, startTime: 10.0)
    let duration = EventLayer.duration(for: kind)

    let beforeStart = EventLayer.apply(to: base, at: 9.99, active: active)
    #expect(beforeStart == base)

    let afterEnd = EventLayer.apply(to: base, at: 10.0 + duration + 0.01, active: active)
    #expect(afterEnd == base)
}

@Test("事件在播放期間覆蓋 effect，且落在規格 §8 的 0.4–2 秒區間內", arguments: allCommands)
func eventDurationsFallWithinSpecRange(kind: AvatarEventCommand) {
    let duration = EventLayer.duration(for: kind)
    #expect(duration >= 0.4)
    #expect(duration <= 2.0)
}

@Test("firstVisit／goalAchieved／weeklyGoalCompleted 用 celebration，其餘四個事件重用剩下四個 AvatarEffect（不發明新 taxonomy）")
func eventsReuseExistingEffectTaxonomy() {
    #expect(EventLayer.effect(for: .firstVisit) == .celebration(.firstVisit))
    #expect(EventLayer.effect(for: .goalAchieved) == .celebration(.goalAchieved))
    #expect(EventLayer.effect(for: .weeklyGoalCompleted) == .celebration(.weeklyGoalCompleted))
    #expect(EventLayer.effect(for: .playful) == .sparkles)
    #expect(EventLayer.effect(for: .memberRecognized) == .hearts)
    #expect(EventLayer.effect(for: .longTimeNoSee) == .hearts)
    #expect(EventLayer.effect(for: .error) == .sweatDrop)
}

@Test("事件只覆蓋它宣告擁有的欄位（effect／effectIntensity／sparkleIntensity），其餘沿用輸入 state（§8 規則 2）")
func eventOnlyOverridesItsOwnFields() {
    let base = mapper.map(.thinking) // 有非零的 pupilOffset、eyebrowTilt 等
    let active = ActiveEvent(kind: .goalAchieved, startTime: 0)
    let result = EventLayer.apply(to: base, at: 0.5, active: active)

    #expect(result.effect == .celebration(.goalAchieved))
    #expect(result.pupilOffset == base.pupilOffset)
    #expect(result.eyebrowTilt == base.eyebrowTilt)
    #expect(result.eyebrowStyle == base.eyebrowStyle)
    #expect(result.mouthStyle == base.mouthStyle)
    #expect(result.eyeOpenAmount == base.eyeOpenAmount)
}

@Test("強度包絡在事件開始與結束的瞬間都是 0，中段是滿強度（0.4–2 秒的淡入淡出）")
func intensityEnvelopeFadesInAndOut() {
    let duration = 1.0
    #expect(EventLayer.intensity(elapsed: 0, duration: duration) == 0)
    #expect(EventLayer.intensity(elapsed: duration, duration: duration) == 0)
    #expect(EventLayer.intensity(elapsed: duration / 2, duration: duration) == 1)

    // 單調上升到 1、再單調下降回 0。
    let samples = stride(from: 0.0, through: duration, by: 0.05).map {
        EventLayer.intensity(elapsed: $0, duration: duration)
    }
    #expect(samples.allSatisfy { (0.0 ... 1.0).contains($0) })
    let peakIndex = samples.firstIndex(of: 1.0)!
    let rampUp = Array(samples[..<peakIndex])
    let rampDown = Array(samples[peakIndex...])
    #expect(rampUp == rampUp.sorted())
    #expect(rampDown == rampDown.sorted(by: >))
}

@Test("事件會把 sparkleIntensity 拉到不低於其強度包絡，但不會蓋掉本來就更高的 base 值")
func eventBoostsSparkleIntensityWithoutLoweringIt() {
    let brightBase = mapper.map(.encouraging) // sparkleIntensity 已經是 1.00
    let active = ActiveEvent(kind: .error, startTime: 0)
    // error 的強度包絡在中段是 1，跟 base 一樣，不會低於 base。
    let result = EventLayer.apply(to: brightBase, at: EventLayer.duration(for: .error) / 2, active: active)
    #expect(result.sparkleIntensity >= brightBase.sparkleIntensity)
}

@Test("事件把既有強度包絡寫入 effectIntensity，並保留 effect taxonomy")
func eventWritesIntensityEnvelopeToEffectIntensity() {
    let base = mapper.map(.idle)
    let active = ActiveEvent(kind: .playful, startTime: 10)
    let duration = EventLayer.duration(for: active.kind)

    let fadeIn = EventLayer.apply(to: base, at: 10.05, active: active)
    #expect(fadeIn.effect == .sparkles)
    #expect(abs(fadeIn.effectIntensity - EventLayer.intensity(elapsed: 0.05, duration: duration)) < 0.0001)

    let middle = EventLayer.apply(to: base, at: 10 + duration / 2, active: active)
    #expect(middle.effect == .sparkles)
    #expect(middle.effectIntensity == 1)

    let fadeOut = EventLayer.apply(to: base, at: 10 + duration - 0.05, active: active)
    #expect(fadeOut.effect == .sparkles)
    #expect(abs(fadeOut.effectIntensity - EventLayer.intensity(elapsed: duration - 0.05, duration: duration)) < 0.0001)
}

@Test("事件在 duration 到達的邊界視為結束，尚未開始仍不覆蓋")
func eventDurationBoundaryIsExclusiveButFutureEventIsUntouched() {
    let base = mapper.map(.idle)
    let active = ActiveEvent(kind: .playful, startTime: 10)
    let duration = EventLayer.duration(for: active.kind)

    let atEnd = EventLayer.apply(to: base, at: 10 + duration, active: active)
    #expect(atEnd == base)

    let beforeStart = EventLayer.apply(to: base, at: 9.99, active: active)
    #expect(beforeStart == base)
}
