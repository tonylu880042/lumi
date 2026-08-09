import SwiftUI
import LumiDomain
import LumiPresentation

/// 唯一負責「讓 Avatar 真的動起來」的 View。擁有 `BlinkSchedule`、透過
/// `TimelineView` 取得時間、呼叫 `AvatarCompositor` 算出最終 `AvatarVisualState`，
/// 再交給純函式的 `LumiAvatarView` 畫出來——`LumiAvatarView` 本身完全不知道
/// 時間、不持有 Timer、不做任何動畫決策，維持「只消費一個 AvatarVisualState」
/// 的純函式性質（CLAUDE.md「只有一個 View 能寫某個參數」，這裡是唯一疊加
/// Continuous 動畫的地方）。
public struct AnimatedLumiAvatarView: View {
    private let base: AvatarVisualState
    private let seed: UInt64

    // `blinkSchedule` 是 Optional 而不是直接在 init 建好：`@State` 的
    // initialValue 只在這個 View 的身份第一次被建立時真正生效，之後每次
    // SwiftUI 重建這個 struct（父層重繪就會發生）都會重新呼叫 init、丟掉那個
    // 值——如果 init 本身就配置 `BlinkSchedule`（一個 horizon 秒數量級的
    // 陣列），等於每次父層重繪都白做一次配置與拋棄。改用 `.task` 在身份建立
    // 後只真正跑一次，body 在排程還沒好之前先畫 base（沒有眨眼，但不阻塞
    // 第一幀），沒有任何一次多餘的配置。
    @State private var blinkSchedule: BlinkSchedule?
    @State private var startInstant = Date()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - state: State 層算出的 base（`AvatarStateMapper` 的輸出）。
    ///   - seed: 眨眼排程的種子。同一個角色實例通常固定用同一個 seed 即可
    ///     ——「可重現」是給測試用的，App 這裡只要求「不是每次都一樣的
    ///     時間表」不是硬性規格，所以給一個預設值就好，呼叫端也可以自己帶。
    public init(state: AvatarVisualState, seed: UInt64 = 0) {
        self.base = state
        self.seed = seed
    }

    public var body: some View {
        TimelineView(.animation) { context in
            if let blinkSchedule {
                // `time` 就是注入的 Clock（見 ContinuousLayer 的設計）：這裡把
                // TimelineView 給的絕對日期換算成「相對於這個 View 開始存在時」
                // 的經過秒數，變成一個單純的 elapsed-seconds TimeInterval。
                let elapsed = context.date.timeIntervalSince(startInstant)
                let composed = AvatarCompositor.compose(
                    base: base,
                    at: elapsed,
                    blinkSchedule: blinkSchedule,
                    reducedMotion: reduceMotion
                )
                LumiAvatarView(state: composed)
            } else {
                LumiAvatarView(state: base)
            }
        }
        .task {
            guard blinkSchedule == nil else { return }
            var rng = SeededGenerator(seed: seed)
            blinkSchedule = BlinkSchedule(using: &rng)
        }
    }
}

#Preview("動畫 Avatar：眨眼、呼吸、微眼動實際在跑") {
    AnimatedLumiAvatarView(state: AvatarStateMapper().map(.idle))
        .frame(width: 420, height: 280)
        .padding()
}
