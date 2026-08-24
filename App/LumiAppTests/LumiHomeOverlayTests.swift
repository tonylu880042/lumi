import Foundation
import Testing
@testable import LumiApp

@MainActor
@Suite("Lumi home overlay")
struct LumiHomeOverlayTests {
    @Test("known visitor copy includes greeting, enrolled count, and recognition result")
    func knownVisitorCopy() {
        let content = LumiHomeStatusPresenter.content(
            for: .known,
            greeting: "Tony，歡迎回來～",
            enrolledMemberCount: 3
        )

        #expect(content.headline == "Tony，歡迎回來～")
        #expect(content.detail == "已建立 3 位訪客 · 已辨識")
    }

    @Test("unknown and in-progress states never imply a known identity")
    func privacySafeNonKnownCopy() {
        #expect(
            LumiHomeStatusPresenter.content(
                for: .recognizing,
                greeting: nil,
                enrolledMemberCount: 3
            ) == LumiHomeStatusContent(
                headline: "正在辨識訪客",
                detail: "已建立 3 位訪客 · 辨識中"
            )
        )
        #expect(
            LumiHomeStatusPresenter.content(
                for: .unknown,
                greeting: "嗨，歡迎妳！",
                enrolledMemberCount: 3
            ) == LumiHomeStatusContent(
                headline: "嗨，歡迎妳！",
                detail: "已建立 3 位訪客 · 未辨識"
            )
        )
    }

    @Test("settings copy makes the optional application hints explicit")
    func settingsCopy() {
        #expect(LumiHomeViewIntent.settingsTitle == "Lumi 設定")
        #expect(LumiHomeViewIntent.hintsToggleTitle == "顯示應用提示")
        #expect(
            LumiHomeViewIntent.hintsToggleDescription
                == "顯示辨識結果與已建立的訪客人數。"
        )
        #expect(LumiHomeViewIntent.showsHintsByDefault)
    }

    @Test("native volume control reserves a visible slider width")
    func nativeVolumeSliderWidth() {
        #expect(SystemVolumeControl.viewIntent.sliderWidth == 260)
    }

    @Test("selected Stitch direction keeps settings, caption, and native volume controls")
    func selectedDirectionStructure() throws {
        let contentSource = try source(named: "ContentView.swift")
        let overlaySource = try source(named: "LumiHomeOverlay.swift")
        let volumeSource = try source(named: "SystemVolumeControl.swift")

        #expect(contentSource.contains("LumiHomeOverlay"))
        #expect(contentSource.contains("@AppStorage"))
        #expect(overlaySource.contains("Toggle("))
        #expect(volumeSource.contains("MPVolumeView"))
    }

    private func source(named fileName: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LumiApp/Sources")
            .appendingPathComponent(fileName)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
