import SwiftUI
import LumiPresentation

/// 唯一負責「讓 Avatar 真的動起來」的 View。擁有 `BlinkSchedule`、透過
/// `TimelineView` 取得時間、呼叫 `AvatarCompositor` 算出最終 `AvatarVisualState`，
/// 再交給純函式的 `LumiAvatarView` 畫出來——`LumiAvatarView` 本身完全不知道
/// 時間、不持有 Timer、不做任何動畫決策，維持「只消費一個 AvatarVisualState」
/// 的純函式性質（CLAUDE.md「只有一個 View 能寫某個參數」，這裡是唯一疊加
/// Continuous 動畫的地方）。
public struct AnimatedLumiAvatarView: View {
    /// The latest state supplied by the parent. SwiftUI recreates this value
    /// when the mapped Presentation state changes; `renderedBase` below is the
    /// state currently being animated by this coordination point.
    private let incomingState: AvatarVisualState
    private let seed: UInt64
    private let processedAmplitude: Double
    private let triggeredEvent: Binding<AvatarEventCommand?>
    private let cancelEvent: Binding<Bool>

    // `blinkSchedule` 是 Optional 而不是直接在 init 建好：`@State` 的
    // initialValue 只在這個 View 的身份第一次被建立時真正生效，之後每次
    // SwiftUI 重建這個 struct（父層重繪就會發生）都會重新呼叫 init、丟掉那個
    // 值。`BlinkSchedule` 雖然已是常數記憶體的輕量值，仍應讓同一個 View 身份
    // 固定使用同一條 deterministic timeline；改用 `.task` 在身份建立後只初始化
    // 一次。body 在排程還沒好之前先畫 base（沒有眨眼，但不阻塞第一幀）。
    @State private var blinkSchedule: BlinkSchedule?
    @State private var renderedBase: AvatarVisualState
    @State private var startInstant = Date()
    /// Presentation-owned lifecycle for the single active event. New triggers
    /// replace the previous event; cancellation and expiry clear this value.
    @State private var playback = AvatarEventPlayback()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - state: State 層算出的 base（`AvatarStateMapper` 的輸出）。
    ///   - seed: 眨眼排程的種子。同一個角色實例通常固定用同一個 seed 即可
    ///     ——「可重現」是給測試用的，App 這裡只要求「不是每次都一樣的
    ///     時間表」不是硬性規格，所以給一個預設值就好，呼叫端也可以自己帶。
    ///   - processedAmplitude: 已由上游平滑、降採樣並限制在 `0...1` 的音訊值；
    ///     預設為 `0`，`waveformMode` 為 `.none` 時由合成器忽略。
    ///   - triggeredEvent: 呼叫端把它設成非 nil 來觸發一個事件（一次性訊號，
    ///     這個 View 收到後會立刻把它讀回 nil，讓下一次設成同一個 case 也能
    ///     再觸發一次）。預設 `.constant(nil)`，不想要事件功能的呼叫端不用管它。
    ///   - cancelEvent: 呼叫端設為 `true` 可明確取消目前事件；View 會在處理後
    ///     將 binding 重設為 `false`。預設 `.constant(false)`。
    public init(
        state: AvatarVisualState,
        seed: UInt64 = 0,
        processedAmplitude: Double = 0,
        triggeredEvent: Binding<AvatarEventCommand?> = .constant(nil),
        cancelEvent: Binding<Bool> = .constant(false)
    ) {
        self.incomingState = state
        self.seed = seed
        self.processedAmplitude = processedAmplitude
        self.triggeredEvent = triggeredEvent
        self.cancelEvent = cancelEvent
        self._renderedBase = State(initialValue: state)
    }

    public var body: some View {
        TimelineView(.animation) { context in
            if let blinkSchedule {
                // `time` 就是注入的 Clock（見 ContinuousLayer 的設計）：這裡把
                // TimelineView 給的絕對日期換算成「相對於這個 View 開始存在時」
                // 的經過秒數，變成一個單純的 elapsed-seconds TimeInterval。
                let elapsed = context.date.timeIntervalSince(startInstant)
                let composed = AvatarCompositor.compose(
                    base: renderedBase,
                    at: elapsed,
                    blinkSchedule: blinkSchedule,
                    activeEvent: playback.activeEvent,
                    processedAmplitude: processedAmplitude,
                    reducedMotion: reduceMotion
                )
                LumiAvatarView(state: composed)
                    .onChange(of: context.date) { _, tickDate in
                        let tickElapsed = tickDate.timeIntervalSince(startInstant)
                        // Read-only on every tick; only an expired event causes
                        // a lifecycle write-back.
                        guard playback.isExpired(at: tickElapsed) else { return }
                        playback.removeExpired(at: tickElapsed)
                    }
            } else {
                LumiAvatarView(state: renderedBase)
            }
        }
        .task {
            guard blinkSchedule == nil else { return }
            var rng = SeededGenerator(seed: seed)
            blinkSchedule = BlinkSchedule(using: &rng)
        }
        .onChange(of: incomingState) { _, newValue in
            if reduceMotion {
                // Reduced Motion preserves the semantic state while removing
                // spring/bounce motion from the transition itself.
                withAnimation(nil) {
                    renderedBase = newValue
                }
            } else {
                withAnimation(animation(for: newValue.transition)) {
                    renderedBase = newValue
                }
            }
        }
        .onChange(of: triggeredEvent.wrappedValue) { _, newValue in
            guard let newValue else { return }
            playback.trigger(newValue, at: Date().timeIntervalSince(startInstant))
            triggeredEvent.wrappedValue = nil
        }
        .onChange(of: cancelEvent.wrappedValue) { _, shouldCancel in
            guard shouldCancel else { return }
            playback.cancel()
            cancelEvent.wrappedValue = false
        }
    }

    private func animation(for transition: AvatarTransition) -> Animation {
        switch transition.curve {
        case .easeInOut:
            return .easeInOut(duration: transition.duration)
        case .easeOut:
            return .easeOut(duration: transition.duration)
        case .spring:
            return .spring(duration: transition.duration)
        case .keyframe:
            // KeyframeAnimator belongs to the Event layer; State transitions
            // have no independent keyframe sequence, so use a conservative
            // ease-in-out fallback here.
            return .easeInOut(duration: transition.duration)
        }
    }
}

#Preview("動畫 Avatar：眨眼、呼吸、微眼動實際在跑") {
    AnimatedLumiAvatarView(state: previewAvatarState)
        .frame(width: 420, height: 280)
        .padding()
}

private let previewAvatarState = AvatarVisualState(
    eyeOpenAmount: 1,
    highlightIntensity: 0.9,
    softGlossOpacity: 0.7,
    blushOpacity: 0.2,
    mouthStyle: .softSmile,
    transition: AvatarTransition(duration: 0.3, curve: .easeInOut)
)
