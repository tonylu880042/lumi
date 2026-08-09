import SwiftUI
import LumiDomain
import LumiPresentation

/// 完整的臉：雙眼、眉毛、腮紅、嘴巴、waveform。純函式消費「一個」`AvatarVisualState`——
/// 沒有 view-model、沒有 `@State` 動畫驅動、沒有計時器。M2/M3 才會疊加 Continuous／
/// Event 層與動畫。
///
/// 固定 640×420 座標系＋scale-to-fit（CLAUDE.md「不做 device 分支」），沒有
/// `isPad` 或 size-class 判斷。
public struct LumiAvatarView: View {
    private let state: AvatarVisualState

    public init(state: AvatarVisualState) {
        self.state = state
    }

    public var body: some View {
        // Scale-to-fit：整張臉永遠畫在同一個 640×420 座標系裡，再依容器可用空間
        // 均勻縮放。`.aspectRatio(_:contentMode:.fit)` 沒辦法縮小一個已經有固定
        // frame 的子樹——它只會決定「這個已經是 640×420 的東西」在版面裡怎麼擺，
        // 不會真的縮放內容，所以塞進比 640×420 小的容器時畫面會被裁切成放大特寫
        // 而不是縮小（P0 review 抓到的正是這個）。改用 GeometryReader 量出容器
        // 大小，自己算 scale 再套 `scaleEffect`，這樣不管容器多小多窄都會整張縮放，
        // 不裁切、不判斷裝置。
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / AvatarTokens.canvasWidth,
                geometry.size.height / AvatarTokens.canvasHeight
            )
            faceContent
                .frame(width: AvatarTokens.canvasWidth, height: AvatarTokens.canvasHeight)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }

    private var faceContent: some View {
        let w = AvatarTokens.canvasWidth
        let cx = w / 2
        let leftEyeX = cx - AvatarTokens.eyeGap / 2
        let rightEyeX = cx + AvatarTokens.eyeGap / 2

        return ZStack {
            LumiEyeView(state: state, side: .left)
                .position(x: leftEyeX, y: AvatarTokens.eyeCY)
            LumiEyeView(state: state, side: .right)
                .position(x: rightEyeX, y: AvatarTokens.eyeCY)

            eyebrow(centerX: leftEyeX, mirrored: true)
            eyebrow(centerX: rightEyeX, mirrored: false)

            Ellipse()
                .fill(AvatarTokens.blush)
                .frame(width: 76, height: 42)
                .opacity(state.blushOpacity)
                .position(x: leftEyeX - AvatarTokens.eyeRX - 22, y: AvatarTokens.blushY)
            Ellipse()
                .fill(AvatarTokens.blush)
                .frame(width: 76, height: 42)
                .opacity(state.blushOpacity)
                .position(x: rightEyeX + AvatarTokens.eyeRX + 22, y: AvatarTokens.blushY)

            mouth
                .position(x: cx, y: AvatarTokens.mouthY)

            if state.waveformMode != .none {
                waveform
                    .position(x: cx, y: AvatarTokens.waveformY)
            }
        }
    }

    // MARK: - Eyebrows

    /// 眉型：由 `eyebrowStyle` 選曲線，`eyebrowTilt` 的大小決定不對稱的抬升量
    /// （§3.2：眉毛由「樣式、旋轉、垂直位移」控制）。eye-lab.html 的 `asym` 只有
    /// 固定 -10pt / -7° 兩個離散值；這裡改用 `|eyebrowTilt|` 等比例縮放，
    /// 讓 thinking（0.35）與 confused（0.45）呈現不同幅度、而不是同一個開關。
    /// 不對稱一律套在左眉，與 eye-lab 的慣例一致，只影響刻意表情，不違反
    /// 「左右眼共用 token」（那條規則管的是眼睛本身的大小／光向／色彩）。
    @ViewBuilder
    private func eyebrow(centerX: CGFloat, mirrored: Bool) -> some View {
        let shape = EyebrowGeometry.curve(for: state.eyebrowStyle)
        let magnitude = mirrored ? abs(state.eyebrowTilt) : 0
        let yOffset = -22 * CGFloat(magnitude)
        let rotation = Angle(degrees: -16 * magnitude)

        EyebrowCurve(start: shape.start, control: shape.control, end: shape.end)
            .stroke(AvatarTokens.brow, style: StrokeStyle(lineWidth: 10, lineCap: .round))
            .frame(width: 92, height: 40)
            .rotationEffect(rotation)
            .position(x: centerX, y: AvatarTokens.browY + yOffset)
    }

    // MARK: - Mouth

    /// 規格 §8／CLAUDE.md「不做對嘴」：`mouthOpenAmount` 只是平滑後的 amplitude，
    /// 不做音素對嘴。>0 時它會取代 style 對應的靜態嘴型（與 eye-lab 的
    /// `speaking` 相同：不是換嘴型，是同一個開口 Path 吃 openAmount）。
    /// State 層目前一律輸出 0，所以這條分支在 M1 不會顯示，但仍必須讀取這個欄位，
    /// 不能寫死 —— Continuous 層接上後才會看到嘴巴真的張開。
    @ViewBuilder
    private var mouth: some View {
        if state.mouthOpenAmount > 0.001 {
            AmplitudeMouth(amount: CGFloat(state.mouthOpenAmount))
                .fill(AvatarTokens.mouth)
        } else {
            switch state.mouthStyle {
            case .neutral:
                MouthCurve(halfWidth: 22, depth: 8)
                    .stroke(AvatarTokens.mouth, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            case .softSmile:
                MouthCurve(halfWidth: 30, depth: 26)
                    .stroke(AvatarTokens.mouth, style: StrokeStyle(lineWidth: 8, lineCap: .round))
            case .smile:
                MouthCurve(halfWidth: 36, depth: 40)
                    .stroke(AvatarTokens.mouth, style: StrokeStyle(lineWidth: 8, lineCap: .round))
            case .wideSmile:
                WideSmileShape()
                    .fill(AvatarTokens.mouth)
            case .smallO:
                Ellipse()
                    .fill(AvatarTokens.mouth)
                    .frame(width: 26, height: 32)
                    .offset(y: 6)
            }
        }
    }

    // MARK: - Waveform

    /// waveform 讀 `audioAmplitude`，嘴巴讀 `mouthOpenAmount`——兩個欄位分開，
    /// 因為 listening 時嘴巴必須維持中性（§5.2）而 waveform 必須動，一個共用欄位
    /// 沒辦法同時滿足兩者。兩者仍然共用 Continuous 層算出的同一個上游 amplitude，
    /// 只是「一個來源、兩個消費者」被解到 LumiPresentation 那一層，View 只負責
    /// 讀對應欄位（CLAUDE.md「不做對嘴」段；P0 review）。固定 bar 輪廓，不得
    /// 每幀隨機。
    private var waveform: some View {
        let profile = AvatarTokens.waveformProfile
        let barW = AvatarTokens.waveformBarWidth
        let gap = AvatarTokens.waveformBarGap
        let maxH = AvatarTokens.waveformMaxHeight
        let amp = CGFloat(state.audioAmplitude)
        let color: Color = state.waveformMode == .microphoneInput
            ? AvatarTokens.waveInput
            : AvatarTokens.waveOutput
        let totalWidth = CGFloat(profile.count) * barW + CGFloat(profile.count - 1) * gap

        return Canvas { context, size in
            for (index, level) in profile.enumerated() {
                let barHeight = max(4, CGFloat(level) * amp * maxH)
                let x = CGFloat(index) * (barW + gap)
                let rect = CGRect(x: x, y: (size.height - barHeight) / 2, width: barW, height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: barW / 2), with: .color(color))
            }
        }
        .frame(width: totalWidth, height: maxH)
    }
}

// MARK: - Eyebrow geometry

private enum EyebrowGeometry {
    struct Curve {
        let start: CGPoint
        let control: CGPoint
        let end: CGPoint
    }

    /// 移植自 eye-lab.html `BROWS`。路徑本身以 x∈[-46,46] 為中心，天然置中。
    static func curve(for style: EyebrowStyle) -> Curve {
        switch style {
        case .neutral, .thinking, .asymmetricConfused:
            // thinking／asymmetricConfused 與 neutral 共用同一條曲線；
            // 不對稱感完全來自呼叫端套用的 eyebrowTilt 位移與旋轉。
            return Curve(start: CGPoint(x: -46, y: 0), control: CGPoint(x: 0, y: -18), end: CGPoint(x: 46, y: 0))
        case .raisedSoft, .joyful:
            return Curve(start: CGPoint(x: -46, y: 6), control: CGPoint(x: 0, y: -24), end: CGPoint(x: 46, y: 4))
        case .attentive:
            return Curve(start: CGPoint(x: -46, y: -4), control: CGPoint(x: 0, y: -12), end: CGPoint(x: 46, y: 0))
        case .concernedSoft:
            return Curve(start: CGPoint(x: -46, y: -6), control: CGPoint(x: 0, y: -20), end: CGPoint(x: 46, y: 2))
        case .relaxed:
            return Curve(start: CGPoint(x: -46, y: 2), control: CGPoint(x: 0, y: -4), end: CGPoint(x: 46, y: 2))
        }
    }
}

private struct EyebrowCurve: Shape {
    let start: CGPoint
    let control: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        var path = Path()
        path.move(to: CGPoint(x: cx + start.x, y: cy + start.y))
        path.addQuadCurve(
            to: CGPoint(x: cx + end.x, y: cy + end.y),
            control: CGPoint(x: cx + control.x, y: cy + control.y)
        )
        return path
    }
}

// MARK: - Mouth shapes

/// 開口式笑容曲線，中心對齊 rect。用於 neutral／softSmile／smile。
///
/// 移植自 eye-lab.html 的 `MOUTHS`，但拿掉了它們各自多餘的
/// `transform="translate(-halfWidth, 0)"`。那個 transform 把本來已經置中的路徑
/// （M -halfWidth 0 ... 對稱到 +halfWidth）又整個往左推了 halfWidth，
/// 結果嘴巴貼齊臉部中線的左邊、完全偏到左半臉——這不像是刻意的表情設計，
/// 更像是重構時留下的殘留 transform。§3 的圖層拆解與 §4 的規則都只講眼睛，
/// 沒有任何一處描述「嘴巴應該偏移中線」，因此判斷為 lab 的殘留 bug 而非
/// 通過審核的視覺決策，改為置中繪製（CLAUDE.md 用語：「應」偏離，原因如上）。
private struct MouthCurve: Shape {
    let halfWidth: CGFloat
    let depth: CGFloat

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        var path = Path()
        path.move(to: CGPoint(x: cx - halfWidth, y: cy))
        path.addQuadCurve(to: CGPoint(x: cx + halfWidth, y: cy), control: CGPoint(x: cx, y: cy + depth))
        return path
    }
}

/// 填色的大笑嘴型，移植自 eye-lab.html `MOUTHS.wideSmile`（同樣拿掉殘留的置中 transform）。
private struct WideSmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        var path = Path()
        path.move(to: CGPoint(x: cx - 42, y: cy - 6))
        path.addQuadCurve(to: CGPoint(x: cx + 42, y: cy - 6), control: CGPoint(x: cx, y: cy + 48))
        path.addQuadCurve(to: CGPoint(x: cx - 42, y: cy - 6), control: CGPoint(x: cx, y: cy + 10))
        path.closeSubpath()
        return path
    }
}

/// amplitude 驅動的開口嘴型，移植自 eye-lab.html `MOUTHS.speaking(a)`。
/// 只在 `mouthOpenAmount > 0` 時使用，取代 style 對應的靜態嘴型。
private struct AmplitudeMouth: Shape {
    let amount: CGFloat

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let rx = 26 + 8 * amount
        let ry = 5 + 22 * amount
        let ellipseCenterY = cy + 4 + 10 * amount

        var path = Path()
        path.addEllipse(in: CGRect(x: cx - rx, y: ellipseCenterY - ry, width: 2 * rx, height: 2 * ry))
        return path
    }
}

#Preview("11 個基準狀態") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320))], spacing: 16) {
            ForEach(Array(previewStates.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 4) {
                    LumiAvatarView(state: item.state)
                        .frame(height: 200)
                    Text(item.name)
                        .font(.caption)
                }
            }
        }
        .padding()
    }
}

private var previewStates: [(name: String, state: AvatarVisualState)] {
    let mapper = AvatarStateMapper()
    return AssistantState.baselineCases.map { (String(describing: $0), mapper.map($0)) }
}
