import Foundation
import LumiDomain

/// 唯一的合成器（CLAUDE.md「動畫三層」）：State → Continuous → Event → Accessibility，
/// 最後一層永遠贏。Event 層是 M3 的範圍，這裡不先蓋樓梯間——`compose` 目前只做
/// State → Continuous → Accessibility 三步，之後要加 Event 只需要在 Continuous
/// 與 Accessibility 中間插一步，不需要先做插件框架。
public enum AvatarCompositor {
    public static func compose(
        base: AvatarVisualState,
        at time: TimeInterval,
        blinkSchedule: BlinkSchedule,
        reducedMotion: Bool
    ) -> AvatarVisualState {
        let continuous = ContinuousLayer.apply(
            to: base, at: time, schedule: blinkSchedule, reducedMotion: reducedMotion
        )
        return applyAccessibility(continuous, base: base, reducedMotion: reducedMotion)
    }

    /// Accessibility 永遠最後生效、永遠贏（§8 優先權規則 1）。即使日後 Event 層
    /// 疏忽了 reducedMotion，這裡仍會把呼吸脈動與微眼動壓回 base——不依賴
    /// 上游每一層都守規矩。
    ///
    /// M2 決定（§4.3／§12）：
    /// - 呼吸脈動、微眼動：關閉，直接採用 base 的值（「保留靜態多點高光」——
    ///   base 的 `highlightIntensity` 本來就不是 0，見 mapper 的
    ///   `highlightNeverFullyDisappears`）。
    /// - 眨眼：保留，但 `ContinuousLayer` 已經用 `gentle` 曲線（smoothstep、
    ///   封頂六成閉合）取代線性全閉，所以這裡不需要、也不應該把它整個關掉——
    ///   直接關掉眨眼會讓角色看起來像壞掉的娃娃眼，比留著更違反「保留狀態可
    ///   辨識性」。
    private static func applyAccessibility(
        _ state: AvatarVisualState, base: AvatarVisualState, reducedMotion: Bool
    ) -> AvatarVisualState {
        guard reducedMotion else { return state }
        return AvatarVisualState(
            eyeOpenAmount: state.eyeOpenAmount,
            eyeSquintAmount: base.eyeSquintAmount,
            irisScale: base.irisScale,
            irisBrightness: base.irisBrightness,
            pupilOffset: base.pupilOffset,
            pupilScale: base.pupilScale,
            highlightIntensity: base.highlightIntensity,
            highlightScale: base.highlightScale,
            softGlossOpacity: base.softGlossOpacity,
            eyelidStyle: base.eyelidStyle,
            eyebrowStyle: base.eyebrowStyle,
            eyebrowTilt: base.eyebrowTilt,
            blushOpacity: base.blushOpacity,
            mouthStyle: base.mouthStyle,
            mouthOpenAmount: base.mouthOpenAmount,
            audioAmplitude: base.audioAmplitude,
            sparkleIntensity: base.sparkleIntensity,
            waveformMode: base.waveformMode,
            effect: base.effect,
            overallBrightness: base.overallBrightness,
            transition: base.transition
        )
    }
}
