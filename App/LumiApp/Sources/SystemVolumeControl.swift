import MediaPlayer
import SwiftUI
import LumiUI

struct SystemVolumeControlViewIntent: Equatable, Sendable {
    let title: String
    let accessibilityHint: String
    let sliderWidth: CGFloat
}

/// Apple's supported user-facing control for system output volume. The app
/// can read `AVAudioSession.outputVolume`, but Apple intentionally provides no
/// API for setting it programmatically.
struct SystemVolumeControl: UIViewRepresentable {
    static let viewIntent = SystemVolumeControlViewIntent(
        title: "語音音量",
        accessibilityHint: "調整 Lumi 語音的系統輸出音量",
        sliderWidth: 260
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
            Image(systemName: "speaker.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AvatarTokens.lash.opacity(0.62))
                .accessibilityHidden(true)

            SystemVolumeControl()
                // `MPVolumeView` has no useful SwiftUI intrinsic width. Give
                // the native slider a concrete slot so its track and thumb
                // remain visible instead of collapsing between the icons.
                .frame(width: SystemVolumeControl.viewIntent.sliderWidth)
                .frame(height: 44)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AvatarTokens.lash.opacity(0.62))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: 340)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }
}
