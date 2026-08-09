import SwiftUI
import LumiPresentation

/// 單眼。§3.1 由後至前：眼白 → 虹膜深色外圈 → 虹膜主體（放射漸層）→ 瞳孔 →
/// 柔光 → 高光 → 眼皮遮罩。
///
/// 左右眼共用完全相同的 token 與光源方向（CLAUDE.md「左右眼共用 token」）——
/// `side` 只用來鏡像睫毛與決定眼睛中心的左右位置，不影響瞳孔位移、顏色或縮放。
public struct LumiEyeView: View {
    public enum Side: Equatable, Sendable {
        case left, right
    }

    private let state: AvatarVisualState
    private let side: Side

    public init(state: AvatarVisualState, side: Side) {
        self.state = state
        self.side = side
    }

    private var mirror: CGFloat { side == .left ? -1 : 1 }

    public var body: some View {
        let rx = AvatarTokens.eyeRX
        let ry = AvatarTokens.eyeRY
        // 三根睫毛裡最長的一根尖端落在中心上方 114pt、外側 101pt（見 `Eyelashes`），
        // 外加 6pt 描邊線寬的一半；padding 必須蓋住這個範圍，否則尖端會被外層
        // frame 的算圖範圍裁掉（P1 review：睫毛尖端曾經跑到 frame 外面）。
        let padding: CGFloat = 30
        let width = 2 * rx + 2 * padding
        let height = 2 * ry + 2 * padding
        let center = CGPoint(x: width / 2, y: height / 2)

        let irisR = AvatarTokens.irisR * CGFloat(state.irisScale)
        let pupilR = AvatarTokens.pupilR * CGFloat(state.pupilScale)

        // §3.1／§4.1：正規化位移已在 AvatarVisualState.init 被 clamp（唯一 clamp 邊界），
        // 這裡只需把已經合法的正規化座標換算成實際點數。
        //
        // travel range 用「虹膜彩色主體」的半徑（irisR * irisBodyScale），不是深色
        // 外圈的 irisR ——外圈在視覺上跟眼框描邊幾乎融為一體，讓它整圈都留在眼白
        // 內對可讀性沒有幫助，卻讓瞳孔可移動的範圍少了六成。彩色主體仍然完全在
        // 眼白內移動，§3.1「瞳孔位移時不得穿出眼白」不受影響。
        let irisBodyR = irisR * AvatarTokens.irisBodyScale
        let ox = CGFloat(state.pupilOffset.x) * (rx - irisBodyR)
        let oy = CGFloat(state.pupilOffset.y) * (ry - irisBodyR)
        let irisCenter = CGPoint(x: center.x + ox, y: center.y + oy)

        // 曲率隨 eyeSquintAmount 微調（§3.2：眼皮由「開合量、曲率」共同控制）。
        let curveDepth = ry * (0.26 + 0.20 * CGFloat(state.eyeSquintAmount))
        // 上眼皮：open=1 時整條曲線（含中點凸出的 curveDepth/2）必須完全退到眼白
        // 橢圓頂端之上；open=0 時完全蓋住整顆眼睛。topMargin 隨 curveDepth 一起
        // 縮放，確保「完全睜開＝眼皮完全不可見」在任何 squint 值下都成立
        // （P1 review：原本用固定的 8pt margin，在 curveDepth 較大時曲線中點會
        // 露出一小截，即使 open=1 也會看見一條假的眼皮線）。
        let open = CGFloat(state.eyeOpenAmount)
        let topMargin = curveDepth / 2 + 6
        let lidY = center.y - ry - topMargin + (1 - open) * (2 * ry + topMargin)
        // 眼皮曲線最低點是否真的伸進了眼白橢圓——只有這樣才需要畫可見的眼皮邊緣線。
        let lidIntersectsAperture = lidY + curveDepth / 2 > center.y - ry

        return ZStack {
            eyeContent(center: center, irisCenter: irisCenter, rx: rx, ry: ry, irisR: irisR, pupilR: pupilR)
                .frame(width: width, height: height)
                // 硬約束：眼框「輪廓」也必須被眼皮遮罩裁切，不只是內部填色 ——
                // 否則半閉眼會被讀成「往下看」而不是「眼皮闔上」。
                //
                // `subtracting` 是真差集（iOS 17 / macOS 14 起可用），不是用
                // even-odd 疊兩個子路徑那種「對稱差」。even-odd 版本會讓 cap
                // 落在橢圓「外面」的部分因為 winding 只被算一次而繼續留在裁切區
                // 內，6pt 的輪廓線又剛好跨在橢圓邊界上，外側 3pt 就會穿過那個
                // 縫隙露出來（P0 review 抓到的正是這個）。
                .clipShape(
                    EyeEllipse(center: center, rx: rx, ry: ry)
                        .subtracting(LidCap(center: center, rx: rx, ry: ry, lidY: lidY, curveDepth: curveDepth))
                )

            // 眼皮邊緣線：畫在遮罩「之外」，只被較大的外框裁切，維持清晰可讀的閉合邊界。
            // 只有眼皮真的裁到眼白時才畫，否則睜眼時會看到一條不該存在的線
            // （P1 review：`listening` 的 0.92 開眼量下曾經看到一條「多餘的橫線」）。
            if lidIntersectsAperture {
                // 外框裁切要跟著曲線的實際延伸範圍走，不能用固定的 +3——闔眼
                // （open=0）時曲線中點會下探到 ry+curveDepth 左右，固定 +3 會把
                // 整條線都裁掉，變成「完全閉眼＝什麼都看不到」的破圖，而不是一條
                // 可讀的閉眼線。
                EyelidEdgeCurve(center: center, rx: rx, lidY: lidY, curveDepth: curveDepth)
                    .stroke(AvatarTokens.lash, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: width, height: height)
                    .clipShape(OuterEyeBound(center: center, rx: rx + 8, ry: ry + curveDepth / 2 + 10))
            }

            // 睫毛：左右鏡像，光源方向不受影響（CLAUDE.md：睫毛可鏡像，光向不可）。
            Eyelashes(center: center, mirror: mirror)
                .stroke(AvatarTokens.lash, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func eyeContent(
        center: CGPoint, irisCenter: CGPoint, rx: CGFloat, ry: CGFloat, irisR: CGFloat, pupilR: CGFloat
    ) -> some View {
        ZStack {
            Ellipse()
                .fill(AvatarTokens.eyeWhite)
                .frame(width: 2 * rx, height: 2 * ry)
                .position(center)

            ZStack {
                Circle()
                    .fill(AvatarTokens.irisRing)
                    .frame(width: 2 * irisR, height: 2 * irisR)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [AvatarTokens.irisMid, AvatarTokens.irisMid, AvatarTokens.irisDeep],
                            center: UnitPoint(x: 0.35, y: 0.30),
                            startRadius: 0,
                            endRadius: irisR * AvatarTokens.irisBodyScale
                        )
                    )
                    .frame(
                        width: 2 * irisR * AvatarTokens.irisBodyScale,
                        height: 2 * irisR * AvatarTokens.irisBodyScale
                    )

                Circle()
                    .fill(AvatarTokens.pupil)
                    .frame(width: 2 * pupilR, height: 2 * pupilR)

                // 柔光／玻璃感（§4.2 第 5 點）。
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.85), Color.white.opacity(0)],
                            center: UnitPoint(x: 0.5, y: 0.35),
                            startRadius: 0,
                            endRadius: irisR * 0.74
                        )
                    )
                    .frame(width: irisR * 1.48, height: irisR * 0.84)
                    .offset(y: -irisR * 0.34)
                    .opacity(0.55 * state.highlightIntensity)

                // 高光（§4.1）：2–4 個不同大小的白色圓，隨虹膜群組一起移動。
                ForEach(Array(AvatarTokens.highlights.enumerated()), id: \.offset) { _, spec in
                    // §4.1：diameterFraction 是「虹膜直徑」的占比，eye-lab.html 對應到
                    // SVG 的 `r = dia * irisR`（半徑），所以直徑要再乘 2
                    // （P1 review：先前漏了這個 2 倍，高光只有規格一半大）。
                    let diameter = 2 * CGFloat(spec.diameterFraction) * irisR * CGFloat(state.highlightScale)
                    Circle()
                        .fill(Color.white)
                        .frame(width: diameter, height: diameter)
                        .offset(x: CGFloat(spec.x) * irisR, y: CGFloat(spec.y) * irisR)
                        .opacity(spec.baseOpacity * state.highlightIntensity)
                }
            }
            .position(irisCenter)

            // 眼框輪廓（在遮罩群組內，會被上面的 clipShape 一起裁切）。
            Ellipse()
                .stroke(AvatarTokens.lash, lineWidth: 6)
                .frame(width: 2 * rx, height: 2 * ry)
                .position(center)
        }
    }
}

/// 眼白橢圓本身。
private struct EyeEllipse: Shape {
    let center: CGPoint
    let rx: CGFloat
    let ry: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry))
    }
}

/// 眼皮蓋住的區域（從眼睛頂端上方一路延伸到眼皮下緣曲線）。
/// 與 `EyeEllipse` 一起用 `Shape.subtracting` 做真差集，不能用 even-odd
/// 疊兩個子路徑（那是對稱差，見 `LumiEyeView.body` 的說明）。
private struct LidCap: Shape {
    let center: CGPoint
    let rx: CGFloat
    let ry: CGFloat
    /// 眼皮下緣（左右兩端）的絕對 Y 座標。
    let lidY: CGFloat
    /// 曲線中點比兩端多下垂的量。
    let curveDepth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topLeft = CGPoint(x: center.x - rx - 4, y: center.y - ry - 4)
        let topRight = CGPoint(x: center.x + rx + 4, y: center.y - ry - 4)
        let right = CGPoint(x: center.x + rx + 4, y: lidY)
        let left = CGPoint(x: center.x - rx - 4, y: lidY)
        path.move(to: topLeft)
        path.addLine(to: topRight)
        path.addLine(to: right)
        path.addQuadCurve(to: left, control: CGPoint(x: center.x, y: lidY + curveDepth))
        path.closeSubpath()
        return path
    }
}

/// 眼皮邊緣的可見描邊（與 `EyeLidOpening` 用同一條曲線，但只畫線不做遮罩）。
private struct EyelidEdgeCurve: Shape {
    let center: CGPoint
    let rx: CGFloat
    let lidY: CGFloat
    let curveDepth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: center.x - rx - 4, y: lidY))
        path.addQuadCurve(
            to: CGPoint(x: center.x + rx + 4, y: lidY),
            control: CGPoint(x: center.x, y: lidY + curveDepth)
        )
        return path
    }
}

/// 眼睛外框的裁切邊界（比眼白橢圓略大），只用來限制眼皮邊緣線與睫毛不外溢。
private struct OuterEyeBound: Shape {
    let center: CGPoint
    let rx: CGFloat
    let ry: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry))
    }
}

/// 外側上緣三根睫毛，左右鏡像（§4.1：光向一致，睫毛可鏡像）。
private struct Eyelashes: Shape {
    let center: CGPoint
    let mirror: CGFloat

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + mirror * x, y: center.y + y)
        }

        var path = Path()
        // M 24 -87 q 22 -11 34 -27
        path.move(to: point(24, -87))
        path.addQuadCurve(to: point(24 + 34, -87 - 27), control: point(24 + 22, -87 - 11))
        // M 47 -72 q 23 -8 36 -21
        path.move(to: point(47, -72))
        path.addQuadCurve(to: point(47 + 36, -72 - 21), control: point(47 + 23, -72 - 8))
        // M 63 -51 q 23 -2 38 -10
        path.move(to: point(63, -51))
        path.addQuadCurve(to: point(63 + 38, -51 - 10), control: point(63 + 23, -51 - 2))
        return path
    }
}
