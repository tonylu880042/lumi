import SwiftUI
import Testing
@testable import LumiApp

@Suite("App display wake controller")
struct AppDisplayWakeControllerTests {
    @Test("Active scene keeps the display awake")
    @MainActor
    func activeSceneDisablesIdleTimer() {
        let recorder = IdleTimerSettingRecorder()
        let controller = AppDisplayWakeController(
            setIdleTimerDisabled: recorder.record
        )

        controller.scenePhaseChanged(to: .active)

        #expect(recorder.values == [true])
    }

    @Test("Temporarily inactive foreground scene keeps the display awake")
    @MainActor
    func inactiveSceneDisablesIdleTimer() {
        let recorder = IdleTimerSettingRecorder()
        let controller = AppDisplayWakeController(
            setIdleTimerDisabled: recorder.record
        )

        controller.scenePhaseChanged(to: .inactive)

        #expect(recorder.values == [true])
    }

    @Test("Background scene restores the system idle timer")
    @MainActor
    func backgroundSceneEnablesIdleTimer() {
        let recorder = IdleTimerSettingRecorder()
        let controller = AppDisplayWakeController(
            setIdleTimerDisabled: recorder.record
        )

        controller.scenePhaseChanged(to: .background)

        #expect(recorder.values == [false])
    }

    @Test("Removing the App root restores the system idle timer")
    @MainActor
    func rootDisappearanceEnablesIdleTimer() {
        let recorder = IdleTimerSettingRecorder()
        let controller = AppDisplayWakeController(
            setIdleTimerDisabled: recorder.record
        )

        controller.scenePhaseChanged(to: .active)
        controller.rootDisappeared()

        #expect(recorder.values == [true, false])
    }
}

@MainActor
private final class IdleTimerSettingRecorder {
    private(set) var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
    }
}
