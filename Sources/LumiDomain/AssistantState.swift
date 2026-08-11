/// 來客相對於裝置的方向。語意層級的方向，不是座標。
/// 連續注視（依實際人臉位置）是 §13 的後續擴充，不在 MVP。
public enum PresenceDirection: Equatable, Sendable, CaseIterable {
    case left, center, right
}

/// Domain 狀態。規格 §5.2 的 12 個 Phase 1 基準狀態。
///
/// 這裡不得出現座標、透明度、時間長度或任何 SwiftUI 型別 —— 那些是
/// `AvatarVisualState` 的事，只有 `AvatarStateMapper` 能跨過這道邊界。
public enum AssistantState: Equatable, Sendable {
    case idle
    case detected(direction: PresenceDirection)
    case rotating
    case recognizing
    case greeting
    case listening
    case thinking
    case speaking
    case encouraging
    case reminding
    case confused
    case offline
}

extension AssistantState {
    /// 測試與 snapshot matrix 用的基準集合。`detected` 取 `.center` 為代表，
    /// 三個方向另有獨立測試；Phase 1 的 `.rotating` 為無參數狀態。
    public static let baselineCases: [AssistantState] = [
        .idle, .detected(direction: .center), .rotating, .recognizing, .greeting,
        .listening, .thinking, .speaking, .encouraging,
        .reminding, .confused, .offline,
    ]
}
