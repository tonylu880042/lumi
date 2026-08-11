/// 規格 §5.3：這些語意上是短暫的「事件」，不適合當作長駐的 `AssistantState`
/// ——觸發後疊加一段時間（§8：通常 0.4–2 秒）的視覺效果，結束後回到當下最新的
/// 主狀態，而不是把它們塞進 `AssistantState` 常駐。
///
/// 跟 `AssistantState` 一樣是 Domain 型別：不含座標、透明度或任何 SwiftUI 型別，
/// 只有 `EventLayer`（Presentation）知道怎麼把它轉成視覺效果。
public enum AssistantEvent: Equatable, Sendable, CaseIterable {
    case playful
    case memberRecognized
    case firstVisit
    case longTimeNoSee
    case goalAchieved
    case weeklyGoalCompleted
    case error
}
