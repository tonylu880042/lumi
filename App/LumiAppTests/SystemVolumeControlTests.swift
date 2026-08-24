import Foundation
import Testing
@testable import LumiApp

@Suite("System volume control")
struct SystemVolumeControlTests {
    @Test("uses the native volume slider with concise accessible copy")
    @MainActor
    func usesNativeVolumeSlider() throws {
        #expect(SystemVolumeControl.viewIntent.title == "語音音量")
        #expect(
            SystemVolumeControl.viewIntent.accessibilityHint
                == "調整 Lumi 語音的系統輸出音量"
        )

        let source = try sourceText(named: "SystemVolumeControl.swift")
        #expect(source.contains("MPVolumeView"))
        #expect(source.contains("showsVolumeSlider = true"))
        #expect(source.contains("AVAudioSession.sharedInstance().outputVolume") == false)
    }

    private func sourceText(named fileName: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsURL
            .deletingLastPathComponent()
            .appendingPathComponent("LumiApp")
            .appendingPathComponent("Sources")
            .appendingPathComponent(fileName)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
