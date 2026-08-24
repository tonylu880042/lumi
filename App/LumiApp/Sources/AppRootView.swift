import SwiftUI
import LumiPresentation

/// The App-visible destination derived from Presentation setup state.
enum AppRootDestination: Equatable {
    case loading
    case setup(message: String?)
    case saving
    case ready
    case failure(message: String)
}

/// Pure App routing and view-intent metadata.
enum AppRootRouting {
    static func destination(for state: DeviceSetupState) -> AppRootDestination {
        switch state {
        case .loading:
            .loading
        case let .setup(message):
            .setup(message: message)
        case .saving:
            .saving
        case .ready:
            .ready
        case let .failure(message):
            .failure(message: message)
        }
    }
}

/// Reserves separate screen corners for the two DEBUG controls that remain
/// visible over the ready Avatar. Keeping this contract in one place prevents
/// the root device action from covering the session-controls affordance.
enum AppOverlayCorner: Equatable {
    case topLeading
    case topTrailing

    var alignment: Alignment {
        switch self {
        case .topLeading:
            .topLeading
        case .topTrailing:
            .topTrailing
        }
    }
}

enum AppOverlayLayout {
    static let deviceSetupControl: AppOverlayCorner = .topLeading
    static let sessionControls: AppOverlayCorner = .topTrailing
}

/// Chooses setup/loading/failure or the already-composed session content.
///
/// The same Presentation model is retained across route changes so a semantic
/// authorization invalidation can return to setup without replacing the
/// Application controller or selecting a Mock voice implementation.
@MainActor
struct AppRootView<ReadyContent: View>: View {
    @Bindable private var setupModel: DeviceSetupModel
    private let readyContent: ReadyContent

    init(
        setupModel: DeviceSetupModel,
        @ViewBuilder content: () -> ReadyContent
    ) {
        _setupModel = Bindable(setupModel)
        readyContent = content()
    }

    var body: some View {
        switch AppRootRouting.destination(for: setupModel.state) {
        case .loading:
            AppRootLoadingView()
        case .setup, .saving, .failure:
            DeviceSetupView(model: setupModel)
        case .ready:
            readyDestination
        }
    }

    private var readyDestination: some View {
        ZStack(alignment: AppOverlayLayout.deviceSetupControl.alignment) {
            readyContent

#if DEBUG
            Button {
                setupModel.requestReset()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .padding(16)
            .accessibilityLabel(DeviceSetupView.viewIntent.resetLabel)
            .accessibilityIdentifier("device-setup-reset")
#endif
        }
#if DEBUG
        .confirmationDialog(
            DeviceSetupView.viewIntent.resetConfirmationTitle,
            isPresented: resetConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button(DeviceSetupView.viewIntent.resetLabel, role: .destructive) {
                Task { await setupModel.confirmReset() }
            }
            Button(DeviceSetupView.viewIntent.cancelLabel, role: .cancel) {
                setupModel.cancelReset()
            }
        } message: {
            Text(DeviceSetupView.viewIntent.resetConfirmationMessage)
        }
#endif
    }

#if DEBUG
    private var resetConfirmationBinding: Binding<Bool> {
        Binding(
            get: { setupModel.isResetConfirmationPresented },
            set: { isPresented in
                guard !isPresented else { return }
                setupModel.cancelReset()
            }
        )
    }
#endif
}

private struct AppRootLoadingView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
            ProgressView("正在載入裝置設定")
                .accessibilityLabel(Text("正在載入裝置設定"))
        }
        .preferredColorScheme(.light)
    }
}
