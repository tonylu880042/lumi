import LumiPresentation
import SwiftUI

/// DEBUG-Live operator surface for the independently consented local memory
/// feature. All storage and session invalidation stay behind Presentation.
public struct MemberMemoryManagementView: View {
    private static let background = Color(
        red: 244.0 / 255.0,
        green: 236.0 / 255.0,
        blue: 250.0 / 255.0
    )

    private static let usageCopy = "用途：讓 Lumi 記得與會員的互動，以及會員本人告知的運動狀態。"
    private static let retentionCopy = "僅在本機保留最近 90 天的結構化見面與本人告知；不保存錄音逐字稿，也不是正式運動紀錄。"
    private static let consentCopy = "啟用前，管理者必須先向會員說明用途並取得會員同意。臉部身份同意不等於本功能同意。"
    private static let identityCopy = "清除或停用本功能記憶，不會刪除臉部身份資料。"
    private static let enableConfirmationCopy = "請確認你已向會員說明本功能，並已取得會員同意。這是管理者確認，不取代會員同意。"

    @Bindable private var model: MemberMemoryManagementModel
    @State private var pendingEnableRowID: String?
    @State private var pendingClearRowID: String?
    @State private var isEnableConfirmationPresented = false
    @State private var isClearConfirmationPresented = false

    public init(model: MemberMemoryManagementModel) {
        _model = Bindable(model)
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Self.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        status
                        memberList
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
                .refreshable {
                    await model.load()
                }
            }
            .navigationTitle("會員互動記憶")
            .confirmationDialog(
                "啟用會員互動記憶",
                isPresented: $isEnableConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("管理者已確認會員同意") {
                    guard let rowID = pendingEnableRowID else { return }
                    pendingEnableRowID = nil
                    Task {
                        await model.setMemoryEnabled(
                            for: rowID,
                            enabled: true,
                            managerConfirmedMemberConsent: true
                        )
                    }
                }
                Button("取消", role: .cancel) {
                    pendingEnableRowID = nil
                }
            } message: {
                Text(Self.enableConfirmationCopy)
            }
            .confirmationDialog(
                "清除本功能記憶？",
                isPresented: $isClearConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("清除記憶", role: .destructive) {
                    guard let rowID = pendingClearRowID else { return }
                    pendingClearRowID = nil
                    Task {
                        await model.clearMemory(for: rowID)
                    }
                }
                Button("取消", role: .cancel) {
                    pendingClearRowID = nil
                }
            } message: {
                Text("只會清除這項功能的結構化記憶，不會刪除臉部身份資料。")
            }
            .task {
                if model.state == .idle {
                    await model.load()
                }
            }
        }
        .preferredColorScheme(.light)
        .accessibilityIdentifier("member-memory-management")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("會員互動記憶")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.primary)

            Text(Self.usageCopy)
                .font(.body)
                .foregroundStyle(.primary)

            Text(Self.retentionCopy)
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(Self.consentCopy)
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(Self.identityCopy)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .loading:
            ProgressView("正在載入會員記憶")
                .accessibilityLabel(Text("正在載入會員記憶"))
        case .idle, .ready:
            EmptyView()
        case let .error(message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .accessibilityLabel(Text(message))
        }

        if let statusMessage = model.statusMessage {
            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(statusMessage))
        }
    }

    @ViewBuilder
    private var memberList: some View {
        if model.state == .ready, model.rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("目前沒有已登錄會員")
                    .font(.headline)
                Text("完成身份登錄後，管理者可在這裡設定會員互動記憶。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("已登錄會員")
                    .font(.title3.weight(.semibold))

                ForEach(model.rows) { row in
                    memberRow(row)
                }
            }
        }
    }

    private func memberRow(_ row: MemberMemoryManagementRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.spokenLabel)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text(row.isMemoryEnabled ? "記憶已啟用" : "記憶已停用")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(row.isMemoryEnabled ? .green : .secondary)
            }

            Text(row.isMemoryEnabled ? "可使用本機互動記憶" : "不讀取或保存本功能記憶")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(row.isMemoryEnabled ? "停用記憶" : "啟用記憶") {
                    if row.isMemoryEnabled {
                        Task {
                            await model.setMemoryEnabled(
                                for: row.id,
                                enabled: false
                            )
                        }
                    } else {
                        pendingEnableRowID = row.id
                        isEnableConfirmationPresented = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isOperating || model.state == .loading)
                .accessibilityIdentifier("member-memory-toggle-\(row.spokenLabel)")

                Button("清除本功能記憶", role: .destructive) {
                    pendingClearRowID = row.id
                    isClearConfirmationPresented = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.isOperating || model.state == .loading)
                .accessibilityIdentifier("member-memory-clear-\(row.spokenLabel)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}
