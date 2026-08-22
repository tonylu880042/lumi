import SwiftUI
import UIKit

/// Keeps Lumi's display awake while its scene remains in the foreground.
///
/// Sources:
/// - https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled
/// - https://developer.apple.com/documentation/swiftui/scenephase
@MainActor
struct AppDisplayWakeController {
    typealias IdleTimerSetter = @MainActor (Bool) -> Void

    private let setIdleTimerDisabled: IdleTimerSetter

    init(setIdleTimerDisabled: @escaping IdleTimerSetter) {
        self.setIdleTimerDisabled = setIdleTimerDisabled
    }

    func scenePhaseChanged(to scenePhase: ScenePhase) {
        setIdleTimerDisabled(scenePhase != .background)
    }

    func rootDisappeared() {
        setIdleTimerDisabled(false)
    }
}

@MainActor
struct AppDisplayWakeModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    private let controller: AppDisplayWakeController

    init() {
        controller = AppDisplayWakeController { isDisabled in
            UIApplication.shared.isIdleTimerDisabled = isDisabled
        }
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                controller.scenePhaseChanged(to: scenePhase)
            }
            .onChange(of: scenePhase) { _, newPhase in
                controller.scenePhaseChanged(to: newPhase)
            }
            .onDisappear {
                controller.rootDisappeared()
            }
    }
}
