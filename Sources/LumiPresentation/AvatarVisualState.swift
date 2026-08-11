/// 規格 §5.1 的正規化範圍。**這是唯一的 clamp 邊界**（§6 設計約束）——
/// 所有數值都在 init 收斂，所以構造不出超範圍的 `AvatarVisualState`。
public enum AvatarRange {
    public static let eyeOpenAmount = 0.0 ... 1.0
    public static let eyeSquintAmount = 0.0 ... 1.0
    public static let pupilOffsetX = -0.65 ... 0.65
    public static let pupilOffsetY = -0.45 ... 0.45
    public static let irisScale = 0.92 ... 1.12
    public static let pupilScale = 0.88 ... 1.08
    public static let unit = 0.0 ... 1.0
    public static let eyebrowTilt = -1.0 ... 1.0
    /// 規格未定義範圍，暫定為倍率。實機校色後再收斂。
    public static let brightness = 0.0 ... 2.0
    public static let highlightScale = 0.5 ... 1.5
}

extension ClosedRange where Bound == Double {
    func clamping(_ v: Double) -> Double { Swift.min(upperBound, Swift.max(lowerBound, v)) }
}

public struct NormalizedOffset: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = AvatarRange.pupilOffsetX.clamping(x)
        self.y = AvatarRange.pupilOffsetY.clamping(y)
    }

    public static let zero = NormalizedOffset(x: 0, y: 0)
}

public enum EyelidStyle: Equatable, Sendable {
    case neutral, happyCurve, focused, sleepy
}

public enum EyebrowStyle: Equatable, Sendable {
    case neutral, raisedSoft, attentive, thinking, joyful
    case concernedSoft, asymmetricConfused, relaxed
}

public enum MouthStyle: Equatable, Sendable {
    case neutral, softSmile, smile, wideSmile, smallO
}

public enum WaveformMode: Equatable, Sendable {
    case none, microphoneInput, audioOutput, processing
}

public enum CelebrationKind: Equatable, Sendable {
    case goalAchieved, weeklyGoalCompleted, firstVisit
}

public enum AvatarEffect: Equatable, Sendable {
    case sparkles, hearts, questionMark, sweatDrop
    case celebration(CelebrationKind)
}

public struct AvatarTransition: Equatable, Sendable {
    public enum Curve: Equatable, Sendable { case easeInOut, easeOut, spring, keyframe }

    /// 秒。規格 §5.2 每個狀態給的是區間，這裡取中位數。
    public let duration: Double
    public let curve: Curve

    public init(duration: Double, curve: Curve) {
        self.duration = Swift.max(0, duration)
        self.curve = curve
    }
}

/// Presentation Model（規格 §6）。純資料：不持有 Timer、Task、Audio Engine、
/// View 或 Closure。左右眼共用同一組欄位，所以非刻意的不對稱在型別上就不可能發生。
public struct AvatarVisualState: Equatable, Sendable {
    // Eyes
    public let eyeOpenAmount: Double
    public let eyeSquintAmount: Double
    public let irisScale: Double
    public let irisBrightness: Double
    public let pupilOffset: NormalizedOffset
    public let pupilScale: Double

    // Watery-eye treatment（§4）
    public let highlightIntensity: Double
    public let highlightScale: Double
    public let softGlossOpacity: Double

    // Expression
    public let eyelidStyle: EyelidStyle
    public let eyebrowStyle: EyebrowStyle
    public let eyebrowTilt: Double
    public let blushOpacity: Double
    public let mouthStyle: MouthStyle
    /// State 層一律輸出 0；實際開口量由 Continuous 層以平滑後的 amplitude 疊加。
    public let mouthOpenAmount: Double

    // Feedback
    /// State 層一律輸出 0；waveform 的實際震幅由 Continuous 層以平滑後的
    /// audio amplitude 疊加。與 `mouthOpenAmount` 是「同一個上游、兩個消費者」
    /// 中的另一個消費者 —— 兩者共用 Continuous 層算出的 amplitude，但欄位分開，
    /// 因為 listening 時嘴巴必須維持中性（§5.2）而 waveform 必須動。
    public let audioAmplitude: Double
    public let sparkleIntensity: Double
    public let waveformMode: WaveformMode
    public let effect: AvatarEffect?
    /// Event decoration opacity. State effects default to visible; no effect always has zero intensity.
    public let effectIntensity: Double

    // Whole-avatar
    public let overallBrightness: Double
    public let transition: AvatarTransition

    public init(
        eyeOpenAmount: Double,
        eyeSquintAmount: Double = 0,
        irisScale: Double = 1.0,
        irisBrightness: Double = 1.0,
        pupilOffset: NormalizedOffset = .zero,
        pupilScale: Double = 1.0,
        highlightIntensity: Double,
        highlightScale: Double = 1.0,
        softGlossOpacity: Double,
        eyelidStyle: EyelidStyle = .neutral,
        eyebrowStyle: EyebrowStyle = .neutral,
        eyebrowTilt: Double = 0,
        blushOpacity: Double,
        mouthStyle: MouthStyle = .neutral,
        mouthOpenAmount: Double = 0,
        audioAmplitude: Double = 0,
        sparkleIntensity: Double = 0,
        waveformMode: WaveformMode = .none,
        effect: AvatarEffect? = nil,
        effectIntensity: Double = 1.0,
        overallBrightness: Double = 1.0,
        transition: AvatarTransition
    ) {
        self.eyeOpenAmount = AvatarRange.eyeOpenAmount.clamping(eyeOpenAmount)
        self.eyeSquintAmount = AvatarRange.eyeSquintAmount.clamping(eyeSquintAmount)
        self.irisScale = AvatarRange.irisScale.clamping(irisScale)
        self.irisBrightness = AvatarRange.brightness.clamping(irisBrightness)
        self.pupilOffset = pupilOffset
        self.pupilScale = AvatarRange.pupilScale.clamping(pupilScale)
        self.highlightIntensity = AvatarRange.unit.clamping(highlightIntensity)
        self.highlightScale = AvatarRange.highlightScale.clamping(highlightScale)
        self.softGlossOpacity = AvatarRange.unit.clamping(softGlossOpacity)
        self.eyelidStyle = eyelidStyle
        self.eyebrowStyle = eyebrowStyle
        self.eyebrowTilt = AvatarRange.eyebrowTilt.clamping(eyebrowTilt)
        self.blushOpacity = AvatarRange.unit.clamping(blushOpacity)
        self.mouthStyle = mouthStyle
        self.mouthOpenAmount = AvatarRange.unit.clamping(mouthOpenAmount)
        self.audioAmplitude = AvatarRange.unit.clamping(audioAmplitude)
        self.sparkleIntensity = AvatarRange.unit.clamping(sparkleIntensity)
        self.waveformMode = waveformMode
        self.effect = effect
        self.effectIntensity = effect == nil ? 0 : AvatarRange.unit.clamping(effectIntensity)
        self.overallBrightness = AvatarRange.brightness.clamping(overallBrightness)
        self.transition = transition
    }
}
