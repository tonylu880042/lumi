import SwiftUI

/// 規格 §6：顏色與幾何常數集中於此，不散落在各個 View。
///
/// 數值忠實移植自 `Avatar/eye-lab.html` 的 `T` object 與 §4.1 高光基準表 ——
/// 那份檔案已對照客戶概念圖審過，這裡不重新設計外觀，只換一種語法寫同樣的數字。
public enum AvatarTokens {
    // MARK: - Canvas

    /// 固定長寬比座標系（CLAUDE.md「不做 device 分支」）。所有幾何都畫在這個
    /// 640×420 的畫布內，View 端用 scale-to-fit 縮放，不判斷裝置尺寸。
    public static let canvasWidth: CGFloat = 640
    public static let canvasHeight: CGFloat = 420

    // MARK: - Eye geometry

    public static let eyeRX: CGFloat = 78
    public static let eyeRY: CGFloat = 92
    /// 兩眼中心點的水平距離。
    public static let eyeGap: CGFloat = 202
    public static let eyeCY: CGFloat = 172
    public static let irisR: CGFloat = 54
    public static let pupilR: CGFloat = 36
    /// 虹膜「彩色主體」相對於 `irisR`（深色外圈半徑）的比例（§3.1 步驟 2/3：
    /// 外圈先畫在 `irisR`，主體漸層畫在這個比例縮小後的半徑）。深色外圈本身
    /// 在視覺上跟眼框描邊（`lash`，同樣接近黑）幾乎融為一體，讓瞳孔的可移動
    /// 範圍以外圈為界只是白白浪費空間、對可讀性沒有幫助，所以瞳孔位移的
    /// 「有效半徑」也用這個比例，而不是外圈的 `irisR`（P1 review：detected 三個
    /// 方向的視線幾乎分不出來，見 `LumiEyeView` 的換算）。單一常數同時餵給繪圖
    /// 與位移換算，兩者不會各自為政、彼此漂移。
    public static let irisBodyScale: CGFloat = 0.88

    // MARK: - Face layout

    public static let browY: CGFloat = 44
    public static let mouthY: CGFloat = 322
    public static let blushY: CGFloat = 288

    // MARK: - Colors

    /// 畫布背景色，移植自 `eye-lab.html`（已審過的淺粉背景）。`LumiAvatarView`
    /// 本身刻意不畫背景（M1 決定，保留可重用性）——這個 token 給宿主（App）用，
    /// 讓背景色跟其他顏色一樣集中在這裡，不是各自宿主臨時挑一個顏色。
    public static let background = Color(hex: 0xFFF8FC)

    public static let eyeWhite = Color.white
    /// §4.2 虹膜深色外圈。
    public static let irisRing = Color(hex: 0x1B0B33)
    /// 品牌主色。
    public static let irisMid = Color(hex: 0x6B34AE)
    /// 虹膜下緣略深色。
    public static let irisDeep = Color(hex: 0x2E1259)
    public static let pupil = Color(hex: 0x140724)
    public static let lash = Color(hex: 0x151515)
    public static let blush = Color(hex: 0xF4A3B4)
    public static let brow = Color(hex: 0x151515)
    public static let mouth = Color(hex: 0xE23F55)
    /// speaking（audioOutput）waveform 顏色。
    public static let waveOutput = Color(hex: 0xE8517A)
    /// listening（microphoneInput）waveform 顏色。
    public static let waveInput = Color(hex: 0x8B5CF6)

    // MARK: - Highlights（§4.1 高光基準表）

    public struct HighlightSpec: Sendable {
        /// 佔虹膜「直徑」的比例（不是半徑）。
        public let diameterFraction: Double
        public let baseOpacity: Double
        /// 局部正規化座標，原點為虹膜中心；x 向右、y 向下。
        public let x: Double
        public let y: Double
    }

    /// 主高光／次高光／環境光回彈，順序即繪製順序（§3.1 步驟 6）。
    public static let highlights: [HighlightSpec] = [
        HighlightSpec(diameterFraction: 0.22, baseOpacity: 1.00, x: -0.28, y: -0.30),
        HighlightSpec(diameterFraction: 0.09, baseOpacity: 0.90, x: -0.05, y: -0.18),
        HighlightSpec(diameterFraction: 0.12, baseOpacity: 0.22, x: 0.25, y: 0.28),
    ]

    // MARK: - Waveform

    /// 固定 bar 輪廓；§8 規定不得每幀隨機。
    public static let waveformProfile: [Double] = [
        0.35, 0.62, 0.48, 0.85, 0.70, 1.0, 0.78, 0.92, 0.55, 0.74,
        1.0, 0.66, 0.88, 0.50, 0.72, 0.40,
    ]
    public static let waveformBarWidth: CGFloat = 7
    public static let waveformBarGap: CGFloat = 6
    public static let waveformMaxHeight: CGFloat = 42
    public static let waveformY: CGFloat = 386
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
