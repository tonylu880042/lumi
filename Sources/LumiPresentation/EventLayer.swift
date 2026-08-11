import Foundation

/// 一次事件觸發的紀錄：哪個事件、什麼時候開始。跟 `BlinkSchedule` 一樣是純資料，
/// 沒有 Timer／Task——「現在算不算還在播」完全由 `EventLayer.apply` 拿 `time` 跟
/// `startTime` 相減決定（§8：Event 是 (base state, time, event) 的純函式）。
///
/// 呼叫端只保留一個 `ActiveEvent?`（不是佇列或陣列）：這就是「不排隊、取代」
/// 的策略（§8 規則 5）——同一個事件再次觸發、或另一個事件進來，呼叫端直接把
/// 這個值換掉；舊的那個從此不會再被傳進 `apply`，也就不會疊加。取消＝呼叫端
/// 把它設回 `nil`。
public struct ActiveEvent: Equatable, Sendable {
    public let kind: AvatarEventCommand
    public let startTime: TimeInterval

    public init(kind: AvatarEventCommand, startTime: TimeInterval) {
        self.kind = kind
        self.startTime = startTime
    }
}

/// Presentation-owned lifecycle value for the single active Avatar event.
/// Triggering replaces the previous event; no queue or additional lifecycle state is kept.
public struct AvatarEventPlayback: Equatable, Sendable {
    public private(set) var activeEvent: ActiveEvent?

    public init() {
        self.activeEvent = nil
    }

    public mutating func trigger(_ kind: AvatarEventCommand, at time: TimeInterval) {
        activeEvent = ActiveEvent(kind: kind, startTime: time)
    }

    public mutating func cancel() {
        activeEvent = nil
    }

    /// Read-only expiry query for frame-driven callers. It never mutates the
    /// playback value, including when the active event is expired.
    public func isExpired(at time: TimeInterval) -> Bool {
        guard let activeEvent else { return false }
        let elapsed = time - activeEvent.startTime
        guard elapsed >= 0 else { return false }
        return !EventLayer.isActive(
            elapsed: elapsed,
            duration: EventLayer.duration(for: activeEvent.kind)
        )
    }

    @discardableResult
    public mutating func removeExpired(at time: TimeInterval) -> Bool {
        guard activeEvent != nil, isExpired(at: time) else { return false }
        self.activeEvent = nil
        return true
    }
}

/// Event 層（§8）：短暫覆蓋，通常 0.4–2 秒，可中斷。純函式——`time` 是注入的
/// Clock，`active` 是注入的「目前有沒有事件在播」，這裡面沒有 Timer、Task、
/// `Date()`。
///
/// 「事件結束後回到最新主狀態」（§5.3／§12 最容易做錯的一條）不是靠這裡記住
/// 「事件開始前的狀態」——那樣一旦呼叫端在事件播放期間換了 `AssistantState`，
/// 這裡記住的舊狀態就過期了。而是反過來：這一層完全不持有任何狀態，每次
/// `apply` 都拿呼叫端「現在」算出的 `state`（State → Continuous 合成後的最新
/// 結果）當輸入；一旦 `time` 超過事件的 duration，就直接原樣回傳這個輸入——
/// 那個輸入本來就已經是最新主狀態疊加 Continuous 之後的結果，不需要另外
/// 「回復」到任何地方，因為它從來沒被取代過，只是被暫時覆蓋。
public enum EventLayer {
    static func isActive(elapsed: TimeInterval, duration: TimeInterval) -> Bool {
        guard elapsed >= 0 else { return false }
        // Account only for a couple of representational ulps, so a caller's
        // `startTime + duration` lands on the same exclusive boundary without
        // swallowing a meaningful just-before-end sample.
        let tolerance = 4 * max(duration.ulp, elapsed.ulp)
        return duration - elapsed > tolerance
    }

    /// 每個事件的持續時間，落在規格 §8 的 0.4–2 秒區間內。
    static func duration(for kind: AvatarEventCommand) -> TimeInterval {
        switch kind {
        case .playful: 0.6
        case .memberRecognized: 1.0
        case .firstVisit: 1.6
        case .longTimeNoSee: 1.2
        case .goalAchieved: 1.8
        case .weeklyGoalCompleted: 1.8
        case .error: 0.8
        }
    }

    /// 事件 → 視覺 `AvatarEffect` 的對應（CLAUDE.md／任務單要求重用既有的
    /// `AvatarEffect`／`CelebrationKind`，不發明第二套 taxonomy）。`CelebrationKind`
    /// 剛好三個 case，對應 `firstVisit`／`goalAchieved`／`weeklyGoalCompleted` 這三個
    /// 「值得慶祝」的事件；其餘四個事件分到 `AvatarEffect` 剩下的四個
    /// 非 celebration case：sparkles＝俏皮、hearts＝溫暖的辨識與久別重逢、
    /// sweatDrop＝出錯時的尷尬。
    static func effect(for kind: AvatarEventCommand) -> AvatarEffect {
        switch kind {
        case .playful: .sparkles
        case .memberRecognized: .hearts
        case .longTimeNoSee: .hearts
        case .error: .sweatDrop
        case .firstVisit: .celebration(.firstVisit)
        case .goalAchieved: .celebration(.goalAchieved)
        case .weeklyGoalCompleted: .celebration(.weeklyGoalCompleted)
        }
    }

    /// 0…1 的強度包絡：淡入淡出各佔 duration 的 30%（上限 0.25 秒），避免事件
    /// 生硬地跳出/消失。這是「現在套用的強度是多少」的唯一依據，純粹是
    /// elapsed／duration 的函式，不需要額外狀態。
    static func intensity(elapsed: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        let fade = min(duration * 0.3, 0.25)
        if elapsed < fade { return max(0, elapsed / fade) }
        if elapsed > duration - fade { return max(0, (duration - elapsed) / fade) }
        return 1
    }

    /// 只覆蓋它宣告擁有的欄位（`effect`、`effectIntensity`、`sparkleIntensity`），其餘沿用輸入的
    /// `state`（§8 規則 2：Event 只覆蓋它宣告擁有的欄位；其餘仍取最新 State）。
    /// 輸出一律再經過 `AvatarVisualState.init`，維持唯一 clamp 邊界。
    public static func apply(
        to state: AvatarVisualState,
        at time: TimeInterval,
        active: ActiveEvent?
    ) -> AvatarVisualState {
        guard let active else { return state }
        let elapsed = time - active.startTime
        let total = duration(for: active.kind)
        // The duration boundary is exclusive: at exactly duration the event has ended.
        guard isActive(elapsed: elapsed, duration: total) else { return state }

        let strength = intensity(elapsed: elapsed, duration: total)
        return AvatarVisualState(
            eyeOpenAmount: state.eyeOpenAmount,
            eyeSquintAmount: state.eyeSquintAmount,
            irisScale: state.irisScale,
            irisBrightness: state.irisBrightness,
            pupilOffset: state.pupilOffset,
            pupilScale: state.pupilScale,
            highlightIntensity: state.highlightIntensity,
            highlightScale: state.highlightScale,
            softGlossOpacity: state.softGlossOpacity,
            eyelidStyle: state.eyelidStyle,
            eyebrowStyle: state.eyebrowStyle,
            eyebrowTilt: state.eyebrowTilt,
            blushOpacity: state.blushOpacity,
            mouthStyle: state.mouthStyle,
            mouthOpenAmount: state.mouthOpenAmount,
            audioAmplitude: state.audioAmplitude,
            sparkleIntensity: max(state.sparkleIntensity, strength),
            waveformMode: state.waveformMode,
            effect: effect(for: active.kind),
            effectIntensity: strength,
            overallBrightness: state.overallBrightness,
            transition: state.transition
        )
    }
}
