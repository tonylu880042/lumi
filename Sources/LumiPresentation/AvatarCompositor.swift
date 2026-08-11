import Foundation

/// 唯一的合成器（CLAUDE.md「動畫三層」）：State → Continuous → Event → Accessibility，
/// 最後一層永遠贏。三層固定，不做插件框架或 registry。
public enum AvatarCompositor {
    public static func compose(
        base: AvatarVisualState,
        at time: TimeInterval,
        blinkSchedule: BlinkSchedule,
        activeEvent: ActiveEvent? = nil,
        processedAmplitude: Double = 0,
        reducedMotion: Bool
    ) -> AvatarVisualState {
        let continuous = ContinuousLayer.apply(
            to: base,
            at: time,
            schedule: blinkSchedule,
            processedAmplitude: processedAmplitude,
            reducedMotion: reducedMotion
        )
        let event = EventLayer.apply(to: continuous, at: time, active: activeEvent)
        let eventIsPlaying = activeEvent.map {
            let elapsed = time - $0.startTime
            return EventLayer.isActive(elapsed: elapsed, duration: EventLayer.duration(for: $0.kind))
        } ?? false
        return applyAccessibility(
            event,
            base: base,
            reducedMotion: reducedMotion,
            eventIsPlaying: eventIsPlaying
        )
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
        _ state: AvatarVisualState,
        base: AvatarVisualState,
        reducedMotion: Bool,
        eventIsPlaying: Bool
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
            effect: state.effect,
            effectIntensity: state.effect == nil
                ? 0
                : (eventIsPlaying ? 1 : state.effectIntensity),
            overallBrightness: base.overallBrightness,
            transition: base.transition
        )
    }
}
