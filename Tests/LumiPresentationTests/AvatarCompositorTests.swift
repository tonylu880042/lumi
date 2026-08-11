import Testing
import LumiDomain
@testable import LumiPresentation

private let mapper = AvatarStateMapper()

@Test("沒有 active Event 時，合成器等同直接套用 Continuous 層")
func composerMatchesContinuousLayerWhenMotionEnabled() {
    var rng = SeededGenerator(seed: 9)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.listening)
    let t = 12.34

    let direct = ContinuousLayer.apply(to: base, at: t, schedule: schedule, reducedMotion: false)
    let composed = AvatarCompositor.compose(base: base, at: t, blinkSchedule: schedule, reducedMotion: false)
    #expect(direct == composed)
}

@Test("合成後所有 12 個基準狀態仍落在合法範圍內", arguments: AssistantState.baselineCases)
func composedValuesStayInRangeForAllBaselineStates(state: AssistantState) {
    var rng = SeededGenerator(seed: 2)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(state)
    let result = AvatarCompositor.compose(base: base, at: 1.0, blinkSchedule: schedule, reducedMotion: false)

    #expect(AvatarRange.eyeOpenAmount.contains(result.eyeOpenAmount))
    #expect(AvatarRange.unit.contains(result.highlightIntensity))
    #expect(AvatarRange.pupilOffsetX.contains(result.pupilOffset.x))
    #expect(AvatarRange.pupilOffsetY.contains(result.pupilOffset.y))
}

@Test("減少動態效果：停用呼吸與微眼動，但保留高光與狀態可辨識性（§4.3／§12）",
      arguments: AssistantState.baselineCases)
func reducedMotionKeepsHighlightsAndStateIdentity(state: AssistantState) {
    var rng = SeededGenerator(seed: 5)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(state)

    for i in stride(from: 0, through: 30, by: 1) {
        let t = Double(i) * 0.5
        let result = AvatarCompositor.compose(base: base, at: t, blinkSchedule: schedule, reducedMotion: true)

        // 脈動／微眼動關閉：位移與高光強度完全等於 base。
        #expect(result.pupilOffset == base.pupilOffset)
        #expect(result.highlightIntensity == base.highlightIntensity)
        // 靜態高光仍在（§4.3：低潮狀態主高光不應完全消失，mapper 已保證 > 0）。
        #expect(result.highlightIntensity > 0)
        // 狀態本身的表情語意不被 Continuous／Accessibility 動到。
        #expect(result.mouthStyle == base.mouthStyle)
        #expect(result.eyebrowStyle == base.eyebrowStyle)
        #expect(result.eyelidStyle == base.eyelidStyle)
    }
}

@Test("減少動態效果不會讓 offline 看起來興奮，也不會把 confused 的視線拉回中央（§8 規則 4）")
func reducedMotionDoesNotViolateLayerBoundaryRules() {
    var rng = SeededGenerator(seed: 5)
    let schedule = BlinkSchedule(using: &rng)

    let offlineBase = mapper.map(.offline)
    let offline = AvatarCompositor.compose(base: offlineBase, at: 3.0, blinkSchedule: schedule, reducedMotion: true)
    #expect(offline.sparkleIntensity ~= offlineBase.sparkleIntensity)
    #expect(offline.overallBrightness ~= offlineBase.overallBrightness)

    let confusedBase = mapper.map(.confused)
    let confused = AvatarCompositor.compose(base: confusedBase, at: 3.0, blinkSchedule: schedule, reducedMotion: true)
    #expect(confused.pupilOffset.x > 0)
}

@Test("合成器將 processed amplitude 傳給 waveform 與 speaking mouth")
func compositorPassesProcessedAmplitudeToContinuousLayer() {
    var rng = SeededGenerator(seed: 5)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.speaking)

    let result = AvatarCompositor.compose(
        base: base,
        at: 0.5,
        blinkSchedule: schedule,
        processedAmplitude: 0.8,
        reducedMotion: false
    )

    #expect(result.audioAmplitude ~= 0.8)
    #expect(result.mouthOpenAmount ~= 0.8)
}

@Test("Reduced Motion 將 audio motion 壓回 base，但保留 waveform mode 的靜態語意")
func compositorReducedMotionSuppressesAudioAmplitudeMotion() {
    var rng = SeededGenerator(seed: 5)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.speaking)

    let result = AvatarCompositor.compose(
        base: base,
        at: 0.5,
        blinkSchedule: schedule,
        processedAmplitude: 0.8,
        reducedMotion: true
    )

    #expect(result.waveformMode == .audioOutput)
    #expect(result.audioAmplitude ~= base.audioAmplitude)
    #expect(result.mouthOpenAmount ~= base.mouthOpenAmount)
}

private func ~= (lhs: Double, rhs: Double) -> Bool { abs(lhs - rhs) < 0.001 }

// MARK: - Event 層合成順序與生命週期（M3：State → Continuous → Event → Accessibility）

@Test("Event 疊加在 Continuous 之後：播放中會覆蓋 effect，其餘欄位仍是 Continuous 合成後的值")
func eventOverlaysAfterContinuous() {
    var rng = SeededGenerator(seed: 21)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.idle)
    let event = ActiveEvent(kind: .playful, startTime: 1.0)

    let withoutEvent = AvatarCompositor.compose(base: base, at: 1.2, blinkSchedule: schedule, reducedMotion: false)
    let withEvent = AvatarCompositor.compose(
        base: base, at: 1.2, blinkSchedule: schedule, activeEvent: event, reducedMotion: false
    )

    #expect(withEvent.effect == .sparkles)
    // Event 沒宣告要動瞳孔位移／眨眼——那些仍然是 Continuous 算出的值。
    #expect(withEvent.pupilOffset == withoutEvent.pupilOffset)
    #expect(withEvent.eyeOpenAmount == withoutEvent.eyeOpenAmount)
}

@Test("事件結束後回到『當下最新的主狀態』，不是事件開始時已過期的舊狀態（§5.3／§12）")
func eventEndReturnsToLatestMainStateNotStaleOne() {
    var rng = SeededGenerator(seed: 21)
    let schedule = BlinkSchedule(using: &rng)

    let listeningBase = mapper.map(.listening)
    let speakingBase = mapper.map(.speaking)
    let event = ActiveEvent(kind: .goalAchieved, startTime: 10.0)
    let duration = EventLayer.duration(for: .goalAchieved)

    // 事件觸發當下，主狀態還是 listening。
    let duringWithListening = AvatarCompositor.compose(
        base: listeningBase, at: 10.5, blinkSchedule: schedule, activeEvent: event, reducedMotion: false
    )
    #expect(duringWithListening.effect == .celebration(.goalAchieved))

    // 事件還在播放中途，呼叫端這時已經把主狀態換成了 speaking。
    let duringWithSpeaking = AvatarCompositor.compose(
        base: speakingBase, at: 10.0 + duration / 2, blinkSchedule: schedule, activeEvent: event, reducedMotion: false
    )
    #expect(duringWithSpeaking.effect == .celebration(.goalAchieved))
    #expect(duringWithSpeaking.waveformMode == .audioOutput) // speaking 自己的欄位沒被蓋掉

    // 事件結束（時間超過 duration）：必須回到「當下」的 speaking 合成結果，
    // 而不是回到事件開始時已經過期的 listening。
    let endTime = 10.0 + duration + 1.0
    let afterEnd = AvatarCompositor.compose(
        base: speakingBase, at: endTime, blinkSchedule: schedule, activeEvent: event, reducedMotion: false
    )
    let expectedIfNeverTriggered = AvatarCompositor.compose(
        base: speakingBase, at: endTime, blinkSchedule: schedule, activeEvent: nil, reducedMotion: false
    )
    #expect(afterEnd == expectedIfNeverTriggered)
    #expect(afterEnd.effect != .celebration(.goalAchieved))
    #expect(afterEnd.waveformMode == .audioOutput)

    // 尤其不能回到 listening 的合成結果——那是事件開始當下、現在已經過期的主狀態。
    let staleIfStuckOnListening = AvatarCompositor.compose(
        base: listeningBase, at: endTime, blinkSchedule: schedule, activeEvent: nil, reducedMotion: false
    )
    #expect(afterEnd != staleIfStuckOnListening)
}

@Test("事件可以被取消：呼叫端把 activeEvent 設回 nil，立刻回到沒有事件時的合成結果")
func eventCanBeCancelled() {
    var rng = SeededGenerator(seed: 4)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.idle)
    let event = ActiveEvent(kind: .playful, startTime: 0)

    let playing = AvatarCompositor.compose(base: base, at: 0.2, blinkSchedule: schedule, activeEvent: event, reducedMotion: false)
    #expect(playing.effect == .sparkles)

    let cancelled = AvatarCompositor.compose(base: base, at: 0.2, blinkSchedule: schedule, activeEvent: nil, reducedMotion: false)
    #expect(cancelled.effect == base.effect)
}

@Test("同一個事件二次觸發用取代而非疊加：只有最新一次觸發的時間軸生效，不會殘留前一次的效果（§8 規則 5）")
func retriggeringEventReplacesRatherThanStacks() {
    var rng = SeededGenerator(seed: 6)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.idle)

    let firstTrigger = ActiveEvent(kind: .playful, startTime: 0)
    let secondTrigger = ActiveEvent(kind: .playful, startTime: 5) // 使用者在 5 秒時又點了一次

    // 若合成器還在用第一次觸發的時間軸，5.1 秒時第一次觸發（duration 0.6s）早已播完。
    let usingLatestTrigger = AvatarCompositor.compose(
        base: base, at: 5.1, blinkSchedule: schedule, activeEvent: secondTrigger, reducedMotion: false
    )
    #expect(usingLatestTrigger.effect == .sparkles) // 第二次觸發還在播

    let usingStaleTrigger = AvatarCompositor.compose(
        base: base, at: 5.1, blinkSchedule: schedule, activeEvent: firstTrigger, reducedMotion: false
    )
    #expect(usingStaleTrigger.effect == base.effect) // 第一次觸發早已播完，不會殘留
}

@Test("Reduced Motion 保留 active Event 的靜態 effect 語意與可見強度，但 sparkle 仍回到 base")
func reducedMotionPreservesActiveEventSemantics() {
    var rng = SeededGenerator(seed: 8)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.idle)
    let event = ActiveEvent(kind: .goalAchieved, startTime: 0)

    let result = AvatarCompositor.compose(
        base: base, at: 0.5, blinkSchedule: schedule, activeEvent: event, reducedMotion: true
    )
    #expect(result.effect == .celebration(.goalAchieved))
    #expect(result.effectIntensity > 0)
    #expect(result.sparkleIntensity == base.sparkleIntensity)
    #expect(result.pupilOffset == base.pupilOffset)
    #expect(result.highlightIntensity == base.highlightIntensity)
}
