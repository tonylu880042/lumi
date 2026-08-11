import Testing
@testable import LumiPresentation

@Test("預設 smoothing factor 0.35 產生可預測的一階低通值")
func defaultSmoothingFactorProducesPredictableValues() {
    var processor = AmplitudeProcessor()

    #expect(processor.process([1.0]) ~= 0.35)
    #expect(processor.process([1.0]) ~= 0.5775)
    #expect(processor.process([0.0]) ~= 0.375375)
}

@Test("一批 samples 依序平滑但只回傳最後一個值")
func processDownsamplesBatchToLastSmoothedValue() {
    var processor = AmplitudeProcessor()

    let result = processor.process([1.0, 0.0, 1.0])

    #expect(result ~= 0.497875)
}

@Test("平滑 state 會跨越多次 process 保留")
func smoothingStateCarriesAcrossBatches() {
    var processor = AmplitudeProcessor()

    #expect(processor.process([1.0, 0.0]) ~= 0.2275)
    #expect(processor.process([1.0]) ~= 0.497875)
}

@Test("空 batch 不改變 state 且回傳目前輸出")
func emptyBatchDoesNotChangeState() {
    var processor = AmplitudeProcessor()
    let before = processor.process([1.0])

    let after = processor.process([])

    #expect(after ~= before)
    #expect(processor.process([1.0]) ~= 0.5775)
}

@Test("raw amplitude 上下界最後會被限制在 0 到 1，且 clamp 後的 state 可繼續平滑")
func rawAmplitudeIsClampedToUnitRange() {
    var lower = AmplitudeProcessor()
    #expect(lower.process([-10.0]) ~= 0)
    #expect(lower.process([1.0]) ~= 0.35)

    var upper = AmplitudeProcessor()
    #expect(upper.process([10.0]) ~= 1)
    #expect(upper.process([0.0]) ~= 0.65)
}

@Test("smoothing factor init 會限制在 0 到 1")
func smoothingFactorIsClampedToUnitRange() {
    var zero = AmplitudeProcessor(smoothingFactor: -1.0)
    #expect(zero.process([1.0]) ~= 0)

    var one = AmplitudeProcessor(smoothingFactor: 2.0)
    #expect(one.process([0.25]) ~= 0.25)
}

@Test("AmplitudeProcessor 是可比較且可跨 concurrency boundary 傳遞的 value type")
func amplitudeProcessorConformsToValueTypeContracts() {
    let lhs = AmplitudeProcessor()
    let rhs = AmplitudeProcessor()
    #expect(lhs == rhs)
    requireSendable(lhs)
}

private func requireSendable<T: Sendable>(_ value: T) {
    _ = value
}

private func ~= (lhs: Double, rhs: Double) -> Bool {
    abs(lhs - rhs) < 0.000001
}
