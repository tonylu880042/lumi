/// Smooths raw audio amplitudes into one normalized value per sample batch.
///
/// The processor is deliberately a value type: callers own the state and can
/// pass a copy to another presentation pipeline without sharing an audio
/// service or registry. A batch is consumed in order, while only its final
/// smoothed sample is emitted to the renderer.
public struct AmplitudeProcessor: Equatable, Sendable {
    /// The normalized low-pass coefficient used for each raw sample.
    private let smoothingFactor: Double

    /// The latest normalized output. An empty batch returns this value.
    private var currentOutput: Double

    public init(smoothingFactor: Double = 0.35) {
        self.smoothingFactor = Self.clamp(smoothingFactor)
        self.currentOutput = 0
    }

    /// Processes a batch in sample order and emits only the final smoothed value.
    ///
    /// Each intermediate smoothed sample is clamped before it becomes state.
    /// This keeps an out-of-range raw sample from poisoning the next batch while
    /// preserving the batch's downsampled (last-value-only) output contract.
    public mutating func process(_ rawSamples: [Double]) -> Double {
        for rawSample in rawSamples {
            let next = currentOutput + smoothingFactor * (rawSample - currentOutput)
            currentOutput = Self.clamp(next)
        }
        return currentOutput
    }

    private static func clamp(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return Swift.min(1, Swift.max(0, value))
    }
}
