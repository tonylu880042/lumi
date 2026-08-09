import SwiftUI
import LumiDomain
import LumiPresentation
import LumiUI

/// 唯一畫面：整頁顯示 `AnimatedLumiAvatarView`，外加一個最小、視覺上不搶眼的
/// 控制項可以在 11 個 `AssistantState` 基準狀態（含三個 `detected` 方向）間切換，
/// 方便在實機上直接判斷調校結果。這是調校用的殼，不是產品 UI——
/// 沒有 view-model、沒有 navigation、沒有持久化（CLAUDE.md 的要求）。
struct ContentView: View {
    @State private var selection = 0

    private let mapper = AvatarStateMapper()

    /// 涵蓋全部 11 個基準狀態，`detected` 的三個方向各自列一項，
    /// 所以清單長度是 13，而不是 `AssistantState.baselineCases` 的 11。
    private static let states: [(label: String, state: AssistantState)] = [
        ("idle", .idle),
        ("detected(left)", .detected(direction: .left)),
        ("detected(center)", .detected(direction: .center)),
        ("detected(right)", .detected(direction: .right)),
        ("recognizing", .recognizing),
        ("greeting", .greeting),
        ("listening", .listening),
        ("thinking", .thinking),
        ("speaking", .speaking),
        ("encouraging", .encouraging),
        ("reminding", .reminding),
        ("confused", .confused),
        ("offline", .offline),
    ]

    var body: some View {
        ZStack(alignment: .top) {
            // 背景色來自 AvatarTokens（規格 §6：顏色集中管理，不在 App 端另挑一個）。
            // LumiAvatarView 本身刻意不畫背景（M1 決定，維持可重用性），由宿主負責，
            // 這裡就是那個宿主。`.ignoresSafeArea()` 確保頂部／底部安全區也不會露出
            // 系統預設背景色，不會有黑邊。
            AvatarTokens.background.ignoresSafeArea()

            AnimatedLumiAvatarView(state: mapper.map(Self.states[selection].state))
                .padding()

            Picker("State", selection: $selection) {
                ForEach(Array(Self.states.enumerated()), id: \.offset) { index, item in
                    Text(item.label).tag(index)
                }
            }
            .pickerStyle(.menu)
            .padding(8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
