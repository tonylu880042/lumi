import MediaPlayer
import SwiftUI
import LumiUI

struct SystemVolumeControlViewIntent: Equatable, Sendable {
    let title: String
    let accessibilityHint: String
}

/// Apple's supported user-facing control for system output volume. The app
/// can read `AVAudioSession.outputVolume`, but Apple intentionally provides no
/// API for setting it programmatically.
struct SystemVolumeControl: UIViewRepresentable {
    static let viewIntent = SystemVolumeControlViewIntent(
        title: "語音音量",
        accessibilityHint: "調整 Lumi 語音的系統輸出音量"
    )

    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsVolumeSlider = true
        volumeView.accessibilityLabel = Self.viewIntent.title
        volumeView.accessibilityHint = Self.viewIntent.accessibilityHint
        return volumeView
    }

    func updateUIView(_ volumeView: MPVolumeView, context: Context) {
        volumeView.accessibilityLabel = Self.viewIntent.title
        volumeView.accessibilityHint = Self.viewIntent.accessibilityHint
    }
}

struct SystemVolumeControlPanel: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(AvatarTokens.lash)
                .accessibilityHidden(true)

            Text(SystemVolumeControl.viewIntent.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AvatarTokens.lash)

            SystemVolumeControl()
                .frame(width: 170, height: 32)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 12)
    }
}
