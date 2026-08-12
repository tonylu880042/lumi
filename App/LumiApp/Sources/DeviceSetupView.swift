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
    let secureFieldPrompt: String
    let secureFieldAccessibilityLabel: String
    let secureFieldAccessibilityValue: String
    let saveLabel: String
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
            secureFieldPrompt,
            secureFieldAccessibilityLabel,
            secureFieldAccessibilityValue,
            saveLabel,
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
/// SwiftUI owns only transient field editing and Presentation actions. It
/// never reaches into Keychain, URLSession, or any other adapter directly.
@MainActor
struct DeviceSetupView: View {
    static let viewIntent = DeviceSetupViewIntent(
        title: "裝置設定",
        instructions: "請貼上此裝置的授權值以啟用語音。",
        secureFieldPrompt: "裝置授權",
        secureFieldAccessibilityLabel: "裝置授權輸入",
        // A secure input must not expose its current value to VoiceOver.
        secureFieldAccessibilityValue: "",
        saveLabel: "儲存",
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

                    SecureField(
                        Self.viewIntent.secureFieldPrompt,
                        text: $model.tokenInput
                    )
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(
                        Text(Self.viewIntent.secureFieldAccessibilityLabel)
                    )
                    .accessibilityValue(
                        Text(Self.viewIntent.secureFieldAccessibilityValue)
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))

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

                    Button {
                        Task { await model.save() }
                    } label: {
                        Text(Self.viewIntent.saveLabel)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                    .accessibilityIdentifier("device-setup-save")

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
