import LumiDomain

/// 規格 §5.2 基準狀態表的唯一實作。
///
/// 同步、可重現的純函式（§6 設計約束）。隨機眨眼、微眼動、amplitude 與人臉
/// 追蹤都不在這裡 —— 那些是 Continuous 層疊加上去的。
public struct AvatarStateMapper: Sendable {
    public init() {}

    public func map(_ state: AssistantState) -> AvatarVisualState {
        switch state {
        case .idle:
            return AvatarVisualState(
                eyeOpenAmount: 0.88,
                highlightIntensity: 0.70, softGlossOpacity: 0.70,
                blushOpacity: 0.15,
                mouthStyle: .softSmile,
                sparkleIntensity: 0.15,
                transition: .init(duration: 0.40, curve: .easeInOut)
            )

        case .detected(let direction):
            return AvatarVisualState(
                eyeOpenAmount: 1.00,
                irisScale: 1.05,
                pupilOffset: .init(x: 0.55 * direction.sign, y: 0),
                highlightIntensity: 0.85, softGlossOpacity: 0.85,
                eyebrowStyle: .raisedSoft,
                blushOpacity: 0.20,
                mouthStyle: .softSmile,
                sparkleIntensity: 0.30,
                transition: .init(duration: 0.22, curve: .easeOut)
            )

        case .recognizing:
            // 「瞳孔跟隨臉部」是 Continuous 層的即時輸入，State 層輸出置中基準。
            return AvatarVisualState(
                eyeOpenAmount: 0.95,
                irisScale: 0.98,
                pupilScale: 0.92,
                highlightIntensity: 0.65, softGlossOpacity: 0.65,
                eyelidStyle: .focused, eyebrowStyle: .attentive,
                blushOpacity: 0.10,
                mouthStyle: .neutral,
                sparkleIntensity: 0.10,
                transition: .init(duration: 0.25, curve: .easeInOut)
            )

        case .greeting:
            return AvatarVisualState(
                eyeOpenAmount: 1.00,
                eyeSquintAmount: 0.15,
                irisScale: 1.08,
                highlightIntensity: 1.00, softGlossOpacity: 1.00,
                eyelidStyle: .happyCurve, eyebrowStyle: .raisedSoft,
                blushOpacity: 0.70,
                mouthStyle: .smile,
                sparkleIntensity: 0.90,
                transition: .init(duration: 0.45, curve: .spring)
            )

        case .listening:
            return AvatarVisualState(
                eyeOpenAmount: 0.92,
                highlightIntensity: 0.75, softGlossOpacity: 0.75,
                eyelidStyle: .focused, eyebrowStyle: .attentive,
                blushOpacity: 0.25,
                mouthStyle: .neutral,
                sparkleIntensity: 0.10,
                waveformMode: .microphoneInput,
                transition: .init(duration: 0.23, curve: .easeInOut)
            )

        case .thinking:
            return AvatarVisualState(
                eyeOpenAmount: 0.88,
                irisScale: 0.97,
                pupilOffset: .init(x: 0.30, y: -0.35),
                highlightIntensity: 0.65, softGlossOpacity: 0.65,
                eyebrowStyle: .thinking, eyebrowTilt: 0.35,
                blushOpacity: 0.15,
                mouthStyle: .smallO,
                sparkleIntensity: 0.35,
                transition: .init(duration: 0.32, curve: .easeInOut)
            )

        case .speaking:
            // mouthOpenAmount 留 0：由 Continuous 層以平滑後的 amplitude 驅動。
            return AvatarVisualState(
                eyeOpenAmount: 0.92,
                highlightIntensity: 0.75, softGlossOpacity: 0.75,
                eyebrowStyle: .raisedSoft,
                blushOpacity: 0.30,
                mouthStyle: .softSmile,
                sparkleIntensity: 0.10,
                waveformMode: .audioOutput,
                transition: .init(duration: 0.17, curve: .easeInOut)
            )

        case .encouraging:
            return AvatarVisualState(
                eyeOpenAmount: 1.00,
                eyeSquintAmount: 0.25,
                irisScale: 1.12,
                pupilScale: 1.06,
                highlightIntensity: 1.00, softGlossOpacity: 1.00,
                eyelidStyle: .happyCurve, eyebrowStyle: .joyful,
                blushOpacity: 0.85,
                mouthStyle: .wideSmile,
                sparkleIntensity: 1.00,
                transition: .init(duration: 0.58, curve: .spring)
            )

        case .reminding:
            return AvatarVisualState(
                eyeOpenAmount: 0.90,
                irisScale: 0.98,
                highlightIntensity: 0.65, softGlossOpacity: 0.65,
                eyebrowStyle: .concernedSoft,
                blushOpacity: 0.25,
                mouthStyle: .softSmile,
                sparkleIntensity: 0.15,
                transition: .init(duration: 0.32, curve: .easeInOut)
            )

        case .confused:
            return AvatarVisualState(
                eyeOpenAmount: 0.86,
                irisScale: 0.96,
                pupilOffset: .init(x: 0.25, y: 0),
                pupilScale: 0.92,
                highlightIntensity: 0.45, softGlossOpacity: 0.45,
                eyebrowStyle: .asymmetricConfused, eyebrowTilt: -0.45,
                blushOpacity: 0.10,
                mouthStyle: .smallO,
                sparkleIntensity: 0.10,
                effect: .questionMark,
                transition: .init(duration: 0.32, curve: .easeInOut)
            )

        case .offline:
            return AvatarVisualState(
                eyeOpenAmount: 0.45,
                irisScale: 0.92,
                irisBrightness: 0.85,
                pupilOffset: .init(x: 0, y: 0.25),
                highlightIntensity: 0.25, softGlossOpacity: 0.25,
                eyelidStyle: .sleepy, eyebrowStyle: .relaxed,
                blushOpacity: 0,
                mouthStyle: .neutral,
                sparkleIntensity: 0,
                overallBrightness: 0.70,
                transition: .init(duration: 0.70, curve: .easeInOut)
            )
        }
    }
}

private extension PresenceDirection {
    /// 來客在左 → 視線往左（負 X）。
    var sign: Double {
        switch self {
        case .left: -1
        case .center: 0
        case .right: 1
        }
    }
}
