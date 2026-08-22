import SwiftUI
import LumiPresentation

/// Static, token-free copy and accessibility metadata for the setup surface.
///
/// Keeping the metadata separate from the view lets App tests verify the
/// privacy boundary without rendering a SwiftUI hierarchy or ever supplying a
/// real authorization value to an accessibility API.
struct DeviceSetupViewIntent: Equatable, Sendable {
    let title: String
    let instructions: String
    let pasteButtonAccessibilityLabel: String
    let reconfigureLabel: String
    let resetLabel: String
    let resetConfirmationTitle: String
    let resetConfirmationMessage: String
    let cancelLabel: String
    let includesQRCodeAffordance: Bool

    var accessibilityLabels: [String] {
        [
            title,
            instructions,
            pasteButtonAccessibilityLabel,
            reconfigureLabel,
            resetLabel,
            resetConfirmationTitle,
            resetConfirmationMessage,
            cancelLabel
        ]
    }
}

/// First-run device authorization screen.
///
/// SwiftUI receives a transient value only through the system paste control
/// and forwards it to Presentation. It never reaches into Keychain,
/// URLSession, or any other adapter directly.
@MainActor
struct DeviceSetupView: View {
    static let viewIntent = DeviceSetupViewIntent(
        title: "裝置設定",
        instructions: "先複製此裝置的授權值，再按下「貼上」啟用語音。",
        pasteButtonAccessibilityLabel: "從剪貼簿啟用語音",
        reconfigureLabel: "重新設定",
        resetLabel: "解除裝置設定",
        resetConfirmationTitle: "解除裝置設定？",
        resetConfirmationMessage: "只會移除目前環境的裝置授權。",
        cancelLabel: "取消",
        includesQRCodeAffordance: false
    )

    @Bindable private var model: DeviceSetupModel

    init(model: DeviceSetupModel) {
        _model = Bindable(model)
    }

    private var isSaving: Bool {
        if case .saving = model.state { return true }
        return false
    }

    private var message: String? {
        switch model.state {
        case let .setup(message):
            message
        case let .failure(message):
            message
        case .loading, .saving, .ready:
            nil
        }
    }

    private var showsReconfiguration: Bool {
        guard case let .setup(message) = model.state else { return false }
        return message == DeviceSetupModel.authorizationInvalidMessage
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(Self.viewIntent.title)
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(Self.viewIntent.instructions)
                        .font(.body)
                        .foregroundStyle(.secondary)

                    if let message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .accessibilityLabel(Text(message))
                    }

                    if isSaving {
                        ProgressView("正在儲存裝置設定")
                            .accessibilityLabel(Text("正在儲存裝置設定"))
                    }

                    PasteButton(payloadType: String.self) { values in
                        guard let rawValue = values.first else { return }
                        Task {
                            await model.savePastedAuthorization(rawValue)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isSaving)
                    .accessibilityLabel(
                        Text(Self.viewIntent.pasteButtonAccessibilityLabel)
                    )
                    .accessibilityIdentifier("device-setup-paste")

                    if showsReconfiguration {
                        Button(Self.viewIntent.reconfigureLabel) {
                            model.beginReconfiguration()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("device-setup-reconfigure")
                    }
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.light)
    }
}
