import Foundation
import LumiDomain

/// 可種子化的 PRNG（SplitMix64），滿足 stdlib 的 `RandomNumberGenerator`。
/// `SystemRandomNumberGenerator` 不可重現，測試需要同 seed 產生同一組眨眼時間
/// （§11.1(5)：Clock／Random 測試不能真的等待，只能用固定輸入重現）。
/// 這不是「發明 RandomSource 協定」——一樣是 stdlib 的協定，只是提供一個具體、
/// 可 seed 的實作。
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        // 0 會讓 SplitMix64 卡在退化序列，給一個非零起點。
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 持續、可重現的眨眼時間軸。§12「等待時間可變」——用可注入的
/// `RandomNumberGenerator` 取得 seed 與首次等待時間，之後以無狀態的 SplitMix64
/// hash 由眨眼序號產生微幅 jitter。時間軸不預先配置一小時的陣列，也不會在每幀
/// 從 t=0 重播 RNG；每次 query 只計算固定數量的候選眨眼，記憶體維持 O(1)。
///
/// 第 n 次眨眼（n > 0）的開始時間為：
///
///     firstStart + 4 * n + jitter(n)
///
/// `jitter(0) == 0`、其餘 jitter 落在 -1...1，因此相鄰間隔落在 2...6 秒。
/// 同一個 seed 與同一個時間輸入永遠得到同一結果，維持純函式性質（時間就是
/// 呼叫端注入的 Clock）。
public struct BlinkSchedule: Sendable {
    private static let nominalInterval: Double = 4.0
    private static let jitterAmplitude: Double = 1.0
    private static let randomUnitScale = 1.0 / 9_007_199_254_740_992.0 // 2^53

    private let seed: UInt64
    private let firstStart: Double

    /// 快關慢開：關眼比開眼快，符合真實眨眼的不對稱曲線（§7.3）。
    static let closeDuration: Double = 0.09
    static let openDuration: Double = 0.15
    static var totalDuration: Double { closeDuration + openDuration }

    /// - Parameter rng: 注入的隨機來源（見 `SeededGenerator`），使排程可重現。
    public init(using rng: inout some RandomNumberGenerator) {
        self.seed = rng.next()
        self.firstStart = Double.random(in: 2 ... 6, using: &rng)
    }

    /// Returns the deterministic start time for a blink ordinal. Internal for tests;
    /// production callers should normally use `closureAmount(at:)`.
    func start(at index: Int) -> Double {
        precondition(index >= 0, "Blink index must be non-negative")
        guard index > 0 else { return firstStart }
        return firstStart
            + Self.nominalInterval * Double(index)
            + jitter(at: index)
    }

    /// 在時間 `t`，眨眼造成的閉合量：0 = 睜開，1 = 全閉。
    ///
    /// - Parameter gentle: 「減少動態效果」時使用——用 smoothstep 取代線性，
    ///   且把最大閉合量壓到六成，避免「說關就關」的跳動感，但仍保留眨眼本身
    ///   （M2 決定：眨眼不是規格明確要求關閉的「大幅位移」，只是把它變得不突兀）。
    func closureAmount(at t: Double, gentle: Bool = false) -> Double {
        guard let start = lastStart(atOrBefore: t) else { return 0 }
        let elapsed = t - start
        guard elapsed >= 0, elapsed < Self.totalDuration else { return 0 }

        let raw: Double = if elapsed < Self.closeDuration {
            elapsed / Self.closeDuration
        } else {
            1 - (elapsed - Self.closeDuration) / Self.openDuration
        }

        guard gentle else { return raw }
        let smoothstep = raw * raw * (3 - 2 * raw)
        return smoothstep * 0.6
    }

    private func lastStart(atOrBefore t: Double) -> Double? {
        guard t.isFinite, t >= firstStart else { return nil }

        // Every start differs from its nominal 4-second slot by at most one
        // second. Checking this fixed-size neighborhood avoids a scan from t=0
        // while still finding the latest start for any practical elapsed time.
        let relativeSlot = floor((t - firstStart) / Self.nominalInterval)
        // `Double(Int.max - 3)` rounds to the same representable value as
        // `Double(Int.max)` on 64-bit platforms. Keep the strict comparison
        // against the latter so the subsequent Int conversion can never trap.
        guard relativeSlot < Double(Int.max) else { return nil }
        let center = Int(relativeSlot)
        let lower = max(0, center - 2)
        let upper = center + 2
        var result: Double?

        for index in lower ... upper {
            let candidate = start(at: index)
            if candidate <= t {
                result = candidate
            }
        }
        return result
    }

    private func jitter(at index: Int) -> Double {
        guard index > 0 else { return 0 }
        var value = seed &+ UInt64(index)
        value &+= 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        let bits = value ^ (value >> 31)
        let unit = Double(bits >> 11) * Self.randomUnitScale
        return (unit * 2 - 1) * Self.jitterAmplitude
    }
}

/// Continuous 層（§8）：眨眼、微眼動、高光呼吸。純函式，`time` 就是注入的 Clock，
/// `schedule` 就是注入的 RandomSource 產物——這裡面沒有 Timer、Task、Date()。
///
/// 只做「低幅度 additive modifier」（§8 表格的參數權限）：疊加在 base 之上，
/// 不覆寫 base 的語意（不把 offline 弄興奮、不把 confused 的視線拉回中央 —— §8 規則 4）。
/// 輸出一律再經過 `AvatarVisualState.init`，維持唯一 clamp 邊界。
public enum ContinuousLayer {
    /// 呼吸週期 = 眨眼區間（2–6 秒）中點 4 秒 × 黃金比例 ≈ 6.47 秒。
    /// 刻意選一個跟眨眼週期不成整數倍關係的值（4 的 1.618 倍不是 2 的倍數也不是
    /// 3 的倍數），避免呼吸峰值規律地卡在眨眼附近（§4.3「不可與固定眨眼形成
    /// 機械式同步」）。
    static let breathingPeriod: Double = 4.0 * 1.618_034
    /// 這是 sin 的振幅，`highlightIntensity` 實際擺動的是「峰對峰」＝2×這個值。
    /// 基準表最小差是 0.05（idle 0.70 對 listening 0.75）；§4.3 要求呼吸的擺動
    /// 明顯小於這個值，比的是峰對峰，不是單邊振幅——量錯這個曾經讓 0.03
    /// （峰對峰 0.06 > 0.05，反而比狀態切換的最小差距還大）騙過測試。0.02
    /// 的峰對峰是 0.04，舒服地小於 0.05。
    static let breathingAmplitude: Double = 0.02

    /// §5.2 idle 微眼動上限 ±0.05 —— 這是「合成後偏移向量的長度」上限，不是
    /// X、Y 個別上限各自 0.05（那樣對角線最大會到 0.05*sqrt(2)≈0.0707，超出規格）。
    /// 用極座標構造：角度連續旋轉、半徑在 0…amplitude 之間脈動，半徑本身就是
    /// 向量長度，所以 |offset| 恆 ≤ amplitude，不需要事後再做一次 clamp。
    static let saccadeAmplitude: Double = 0.05
    /// 角度旋轉週期與半徑脈動週期互質，避免軌跡變成固定的橢圓來回（看起來機械）。
    static let saccadeAnglePeriod: Double = 0.87
    static let saccadeRadiusPeriod: Double = 1.31

    public static func apply(
        to base: AvatarVisualState,
        at time: TimeInterval,
        schedule: BlinkSchedule,
        processedAmplitude: Double = 0,
        reducedMotion: Bool
    ) -> AvatarVisualState {
        let closure = schedule.closureAmount(at: time, gentle: reducedMotion)
        let eyeOpenAmount = base.eyeOpenAmount * (1 - closure)

        let breathing = breathingAmplitude * sin(2 * .pi * time / breathingPeriod)

        // 微眼動：§5.2 只有清醒、有在互動的狀態才會出現眼球游移；`sleepy` 眼皮
        // （目前只有 offline 用）代表休息／離線，瞳孔還在抖動會像壞掉而不是睡著，
        // 所以直接關掉。判斷式刻意只讀 `AvatarVisualState.eyelidStyle`，不是因為
        // Continuous 技術上看不到 `AssistantState`（LumiPresentation 本來就 import
        // LumiDomain，AvatarStateMapper 就是這樣用的）——而是設計選擇：Continuous
        // 只認 State 層producer 的輸出，不管上游是哪個 AssistantState 產生的，這樣
        // 它才能獨立於 Domain 的形狀組合。這個判準耦合在「sleepy＝該關掉微眼動」
        // 這個巧合上：目前只有 offline 用 sleepy，但沒有測試釘住這個對應關係，
        // 未來如果新增別的 sleepy 狀態、或 offline 改用別的 eyelidStyle，這裡會
        // 悄悄壞掉。`offlineMapsToSleepyEyelid` 這條測試就是釘住它的。
        let saccadeEnabled = base.eyelidStyle != .sleepy
        let saccadeAngle = 2 * Double.pi * time / saccadeAnglePeriod
        let saccadeRadius = saccadeEnabled
            ? saccadeAmplitude * (0.5 + 0.5 * sin(2 * .pi * time / saccadeRadiusPeriod))
            : 0
        let saccadeX = saccadeRadius * cos(saccadeAngle)
        let saccadeY = saccadeRadius * sin(saccadeAngle)

        let normalizedAmplitude = AvatarRange.unit.clamping(processedAmplitude)
        let audioAmplitude: Double
        let mouthOpenAmount: Double
        switch base.waveformMode {
        case .none:
            audioAmplitude = 0
            mouthOpenAmount = 0
        case .audioOutput:
            audioAmplitude = normalizedAmplitude
            mouthOpenAmount = normalizedAmplitude
        case .microphoneInput, .processing:
            audioAmplitude = normalizedAmplitude
            mouthOpenAmount = base.mouthOpenAmount
        }

        return AvatarVisualState(
            eyeOpenAmount: eyeOpenAmount,
            eyeSquintAmount: base.eyeSquintAmount,
            irisScale: base.irisScale,
            irisBrightness: base.irisBrightness,
            // 加在 base 的視線上，不取代——thinking／confused 等狀態自己的
            // 瞳孔位移必須維持語意（§8 規則 4）。
            pupilOffset: NormalizedOffset(
                x: base.pupilOffset.x + saccadeX,
                y: base.pupilOffset.y + saccadeY
            ),
            pupilScale: base.pupilScale,
            highlightIntensity: base.highlightIntensity + breathing,
            highlightScale: base.highlightScale,
            softGlossOpacity: base.softGlossOpacity,
            eyelidStyle: base.eyelidStyle,
            eyebrowStyle: base.eyebrowStyle,
            eyebrowTilt: base.eyebrowTilt,
            blushOpacity: base.blushOpacity,
            mouthStyle: base.mouthStyle,
            mouthOpenAmount: mouthOpenAmount,
            audioAmplitude: audioAmplitude,
            sparkleIntensity: base.sparkleIntensity,
            waveformMode: base.waveformMode,
            effect: base.effect,
            effectIntensity: base.effectIntensity,
            overallBrightness: base.overallBrightness,
            transition: base.transition
        )
    }
}
