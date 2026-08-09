import Testing
import LumiDomain
@testable import LumiPresentation

private let mapper = AvatarStateMapper()
private func ~= (lhs: Double, rhs: Double) -> Bool { abs(lhs - rhs) < 0.001 }

// MARK: - §11.1(1) Mapper：每個狀態產生正確的 AvatarVisualState

@Test("greeting 是最亮、最溫暖的迎賓表情（規格 §11.2 示例）")
func greetingUsesBrightWateryEyesAndWarmExpression() {
    let r = mapper.map(.greeting)
    #expect(r.eyeOpenAmount ~= 1.00)
    #expect(r.irisScale ~= 1.08)
    #expect(r.highlightIntensity ~= 1.00)
    #expect(r.blushOpacity ~= 0.70)
    #expect(r.eyebrowStyle == .raisedSoft)
    #expect(r.mouthStyle == .smile)
    #expect(r.waveformMode == .none)
}

@Test("§5.2 基準表的眼睛數值", arguments: [
    (AssistantState.idle,                       0.88, 1.00, 1.00),
    (.detected(direction: .center),             1.00, 1.05, 1.00),
    (.recognizing,                              0.95, 0.98, 0.92),
    (.greeting,                                 1.00, 1.08, 1.00),
    (.listening,                                0.92, 1.00, 1.00),
    (.thinking,                                 0.88, 0.97, 1.00),
    (.speaking,                                 0.92, 1.00, 1.00),
    (.encouraging,                              1.00, 1.12, 1.06),
    (.reminding,                                0.90, 0.98, 1.00),
    (.confused,                                 0.86, 0.96, 0.92),
    (.offline,                                  0.45, 0.92, 1.00),
])
func baselineEyeValues(state: AssistantState, open: Double, iris: Double, pupil: Double) {
    let r = mapper.map(state)
    #expect(r.eyeOpenAmount ~= open)
    #expect(r.irisScale ~= iris)
    #expect(r.pupilScale ~= pupil)
}

@Test("11 個基準狀態都有明確 mapping，沒有任何一個靜默落回 idle（§5.3、§12）")
func everyBaselineStateHasDistinctMapping() {
    let results = AssistantState.baselineCases.map(mapper.map)
    #expect(results.count == 11)
    // idle 以外不得與 idle 完全相同 —— 相同就代表漏了 mapping
    let idle = mapper.map(.idle)
    #expect(results.dropFirst().allSatisfy { $0 != idle })
}

// MARK: - §11.1(2) 邊界測試

@Test("clamp 邊界擋掉超範圍輸入（§6：單一 clamp 邊界）")
func outOfRangeValuesAreClamped() {
    let r = AvatarVisualState(
        eyeOpenAmount: 9, irisScale: 99,
        pupilOffset: .init(x: -5, y: 5), pupilScale: -3,
        highlightIntensity: 7, softGlossOpacity: -1,
        blushOpacity: 4, sparkleIntensity: -2,
        transition: .init(duration: -1, curve: .easeInOut)
    )
    #expect(r.eyeOpenAmount ~= 1.0)
    #expect(r.irisScale ~= 1.12)
    #expect(r.pupilOffset.x ~= -0.65)
    #expect(r.pupilOffset.y ~= 0.45)
    #expect(r.pupilScale ~= 0.88)
    #expect(r.highlightIntensity ~= 1.0)
    #expect(r.softGlossOpacity ~= 0.0)
    #expect(r.blushOpacity ~= 1.0)
    #expect(r.sparkleIntensity ~= 0.0)
    #expect(r.transition.duration ~= 0.0)
}

@Test("所有狀態的輸出都落在規格範圍內", arguments: AssistantState.baselineCases)
func mappedValuesStayInRange(state: AssistantState) {
    let r = mapper.map(state)
    #expect(AvatarRange.eyeOpenAmount.contains(r.eyeOpenAmount))
    #expect(AvatarRange.irisScale.contains(r.irisScale))
    #expect(AvatarRange.pupilScale.contains(r.pupilScale))
    #expect(AvatarRange.pupilOffsetX.contains(r.pupilOffset.x))
    #expect(AvatarRange.pupilOffsetY.contains(r.pupilOffset.y))
    #expect(AvatarRange.unit.contains(r.highlightIntensity))
    #expect(AvatarRange.unit.contains(r.blushOpacity))
    #expect(AvatarRange.unit.contains(r.sparkleIntensity))
    #expect(AvatarRange.unit.contains(r.audioAmplitude))
    #expect(r.transition.duration > 0)
}

// MARK: - 注視方向

@Test("detected 依來客方向移動視線，Y 不動（§11.2 示例）")
func detectedLooksTowardPresence() {
    #expect(mapper.map(.detected(direction: .left)).pupilOffset.x < 0)
    #expect(mapper.map(.detected(direction: .right)).pupilOffset.x > 0)
    #expect(mapper.map(.detected(direction: .center)).pupilOffset.x ~= 0)

    for d in PresenceDirection.allCases {
        let r = mapper.map(.detected(direction: d))
        #expect(r.pupilOffset.y ~= 0)
        #expect(r.eyeOpenAmount ~= 1.0)
    }
}

// MARK: - §4.3 水汪汪規則

@Test("低潮狀態也不得讓主高光完全消失（§4.3）", arguments: [AssistantState.confused, .offline])
func highlightNeverFullyDisappears(state: AssistantState) {
    #expect(mapper.map(state).highlightIntensity > 0)
}

// MARK: - 分層契約

@Test("State 層一律不輸出 mouthOpenAmount —— 開口量屬於 Continuous 層",
      arguments: AssistantState.baselineCases)
func stateLayerNeverDrivesMouthOpening(state: AssistantState) {
    #expect(mapper.map(state).mouthOpenAmount ~= 0)
}

@Test("State 層一律不輸出 audioAmplitude —— waveform 震幅也屬於 Continuous 層",
      arguments: AssistantState.baselineCases)
func stateLayerNeverDrivesAudioAmplitude(state: AssistantState) {
    #expect(mapper.map(state).audioAmplitude ~= 0)
}

@Test("waveform 只出現在 listening 與 speaking，offline 必須沒有（§5.2）")
func waveformOnlyWhereSpecified() {
    #expect(mapper.map(.listening).waveformMode == .microphoneInput)
    #expect(mapper.map(.speaking).waveformMode == .audioOutput)
    #expect(mapper.map(.offline).waveformMode == .none)

    let others: [AssistantState] = [.idle, .greeting, .thinking, .encouraging, .reminding, .confused]
    #expect(others.allSatisfy { mapper.map($0).waveformMode == .none })
}

@Test("Mapper 是純函式：同輸入同輸出", arguments: AssistantState.baselineCases)
func mapperIsPureAndReproducible(state: AssistantState) {
    #expect(mapper.map(state) == mapper.map(state))
    #expect(AvatarStateMapper().map(state) == AvatarStateMapper().map(state))
}
