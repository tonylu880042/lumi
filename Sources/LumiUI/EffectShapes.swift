import SwiftUI

/// `Avatar/eye-lab.html` 的 `SPARKLE`／`HEART`／`QMARK`／`SWEAT` 這四個 path 常數的
/// SwiftUI 移植（M3 任務單 Part 3：「這些是核准的裝飾形狀；照抄，不重新設計」）。
///
/// 原始 SVG 用 `viewBox="-20 -20 40 40"`，原點在正中央。這裡固定在同一個
/// 40×40 的本地座標系作畫（`pt` 只是把原點平移到 (20, 20)，數字完全照抄自
/// eye-lab.html 的 path data），呼叫端一律配 `.frame(width: 40, height: 40)`
/// 再用 `.scaleEffect` 決定實際顯示大小——形狀本身不因為畫在多大的 `rect` 裡
/// 而變形或重新計算比例。
private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + 20, y: y + 20) }

/// 移植自 `SPARKLE`：`M 0 -16 Q 3 -3 16 0 Q 3 3 0 16 Q -3 3 -16 0 Q -3 -3 0 -16 Z`
struct SparkleShape: Shape {
    func path(in _: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0, -16))
        path.addQuadCurve(to: pt(16, 0), control: pt(3, -3))
        path.addQuadCurve(to: pt(0, 16), control: pt(3, 3))
        path.addQuadCurve(to: pt(-16, 0), control: pt(-3, 3))
        path.addQuadCurve(to: pt(0, -16), control: pt(-3, -3))
        path.closeSubpath()
        return path
    }
}

/// 移植自 `HEART`：
/// `M 0 14 C -18 2 -18 -12 -8 -12 C -3 -12 0 -8 0 -5 C 0 -8 3 -12 8 -12 C 18 -12 18 2 0 14 Z`
struct HeartShape: Shape {
    func path(in _: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0, 14))
        path.addCurve(to: pt(-8, -12), control1: pt(-18, 2), control2: pt(-18, -12))
        path.addCurve(to: pt(0, -5), control1: pt(-3, -12), control2: pt(0, -8))
        path.addCurve(to: pt(8, -12), control1: pt(0, -8), control2: pt(3, -12))
        path.addCurve(to: pt(0, 14), control1: pt(18, -12), control2: pt(18, 2))
        path.closeSubpath()
        return path
    }
}

/// 移植自 `QMARK` 的鉤子部分：
/// `M -7 -12 q 0 -9 8 -9 q 8 0 8 8 q 0 6 -6 9 q -3 2 -3 6`（相對座標已換算成絕對座標）。
/// 原始 SVG 是「一條 stroke path ＋一個獨立的 fill circle」兩個元素疊在一起，
/// 這裡拆成 `QuestionMarkHook`／`QuestionMarkDot` 兩個 Shape，用法見
/// `LumiAvatarView.questionMarkDecoration`。
struct QuestionMarkHook: Shape {
    func path(in _: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(-7, -12))
        path.addQuadCurve(to: pt(1, -21), control: pt(-7, -21))
        path.addQuadCurve(to: pt(9, -13), control: pt(9, -21))
        path.addQuadCurve(to: pt(3, -4), control: pt(9, -7))
        path.addQuadCurve(to: pt(0, 2), control: pt(0, -2))
        return path
    }
}

/// 移植自 `QMARK` 的圓點：`<circle cx="0" cy="14" r="3.2"/>`。
struct QuestionMarkDot: Shape {
    func path(in _: CGRect) -> Path {
        let c = pt(0, 14)
        let r: CGFloat = 3.2
        return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
}

/// 移植自 `SWEAT`：
/// `M 0 -14 C 7 -3 10 3 10 7 A 10 10 0 0 1 -10 7 C -10 3 -7 -3 0 -14 Z`
/// SVG 的橢圓弧（`A 10 10 0 0 1 -10 7`）等價於一個以 `(0, 7)` 為圓心、半徑 10、
/// 經過正下方 `(0, 17)` 的半圓（兩端點 `(10, 7)`／`(-10, 7)` 間距正好是
/// 20＝兩倍半徑）。實測 SwiftUI 的 `addArc(clockwise:)` 在這個座標系下
/// `clockwise: false` 才會經過下方（`true` 反而畫出上方那段、圖形整個反過來）
/// ——`clockwise` 的方向不是直接照抄 SVG sweep-flag 數字可以決定的，這裡以
/// 實際畫出來的水滴形狀為準（有 render 出來的 PNG 比對，不是憑空猜的）。
struct SweatDropShape: Shape {
    func path(in _: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0, -14))
        path.addCurve(to: pt(10, 7), control1: pt(7, -3), control2: pt(10, 3))
        path.addArc(center: pt(0, 7), radius: 10, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.addCurve(to: pt(0, -14), control1: pt(-10, 3), control2: pt(-7, -3))
        path.closeSubpath()
        return path
    }
}
