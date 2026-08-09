import Testing
import LumiDomain
@testable import LumiPresentation

private let mapper = AvatarStateMapper()

@Test("合成器在一般模式下等同直接套用 Continuous 層（M2 還沒有 Event 層可覆蓋）")
func composerMatchesContinuousLayerWhenMotionEnabled() {
    var rng = SeededGenerator(seed: 9)
    let schedule = BlinkSchedule(using: &rng)
    let base = mapper.map(.listening)
    let t = 12.34

    let direct = ContinuousLayer.apply(to: base, at: t, schedule: schedule, reducedMotion: false)
    let composed = AvatarCompositor.compose(base: base, at: t, blinkSchedule: schedule, reducedMotion: false)
    #expect(direct == composed)
}

@Test("合成後所有 11 個基準狀態仍落在合法範圍內", arguments: AssistantState.baselineCases)
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

private func ~= (lhs: Double, rhs: Double) -> Bool { abs(lhs - rhs) < 0.001 }
