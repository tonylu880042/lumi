import SwiftUI
import LumiUI

struct LumiHomeStatusContent: Equatable, Sendable {
    let headline: String
    let detail: String
}

enum LumiHomeViewIntent {
    static let settingsTitle = "Lumi 設定"
    static let hintsToggleTitle = "顯示應用提示"
    static let hintsToggleDescription = "顯示辨識結果與已建立的訪客人數。"
    static let showsHintsByDefault = true
    static let hintsStorageKey = "lumi.home.shows-application-hints"
}

enum LumiHomeStatusPresenter {
    static func content(
        for status: SessionSimulationModel.RecognitionDisplayStatus,
        greeting: String?,
        enrolledMemberCount: Int?
    ) -> LumiHomeStatusContent {
        let count = enrolledMemberCount.map { "已建立 \($0) 位訪客" }
            ?? "訪客人數載入中"

        switch status {
        case .waiting:
            return LumiHomeStatusContent(
                headline: "正在等待訪客",
                detail: "\(count) · 等待中"
            )
        case .recognizing:
            return LumiHomeStatusContent(
                headline: "正在辨識訪客",
                detail: "\(count) · 辨識中"
            )
        case .known:
            return LumiHomeStatusContent(
                headline: greeting ?? "歡迎回來～",
                detail: "\(count) · 已辨識"
            )
        case .unknown:
            return LumiHomeStatusContent(
                headline: greeting ?? "嗨，歡迎妳！",
                detail: "\(count) · 未辨識"
            )
        }
    }
}

struct LumiHomeOverlay: View {
    let status: SessionSimulationModel.RecognitionDisplayStatus
    let greeting: String?
    let enrolledMemberCount: Int?
    let showsApplicationHints: Bool
    let openSettings: () -> Void

    private var content: LumiHomeStatusContent {
        LumiHomeStatusPresenter.content(
            for: status,
            greeting: greeting,
            enrolledMemberCount: enrolledMemberCount
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if showsApplicationHints {
                    VStack(spacing: 7) {
                        Text(content.headline)
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .foregroundStyle(AvatarTokens.lash)

                        Text(content.detail)
                            .font(.system(.footnote, design: .rounded, weight: .medium))
                            .foregroundStyle(AvatarTokens.lash.opacity(0.58))
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .position(
                        x: geometry.size.width / 2,
                        y: min(geometry.size.height * 0.70, geometry.size.height - 150)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(content.headline)，\(content.detail)")
                }

                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(AvatarTokens.lash.opacity(0.72))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topTrailing
                )
                .padding(.top, 8)
                .padding(.trailing, 10)
                .accessibilityLabel(LumiHomeViewIntent.settingsTitle)

                SystemVolumeControlPanel()
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottom
                    )
            }
        }
    }
}

struct LumiHomeSettingsView: View {
    @Binding var showsApplicationHints: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(
                        LumiHomeViewIntent.hintsToggleTitle,
                        isOn: $showsApplicationHints
                    )
                    .tint(AvatarTokens.irisMid)
                } footer: {
                    Text(LumiHomeViewIntent.hintsToggleDescription)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AvatarTokens.background)
            .navigationTitle(LumiHomeViewIntent.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}
