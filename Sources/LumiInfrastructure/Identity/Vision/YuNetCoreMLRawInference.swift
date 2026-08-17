// Xcode 26 still imports MLModel without complete concurrency annotations.
// Keep that compatibility shim local: MLModel stays actor-isolated and no
// Core ML object crosses the Sendable driver boundary.
@preconcurrency import CoreML
import Foundation

/// Stable, payload-free failures at the YuNet Core ML raw-output boundary.
enum YuNetCoreMLRawInferenceError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case failed

    var description: String { "YuNet Core ML raw inference failed." }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}

/// Framework-free driver boundary used by the facade and deterministic tests.
/// Core ML objects remain inside the concrete actor implementation.
protocol YuNetCoreMLRawInferenceDriver: Sendable {
    func predict(values: [Float]) async throws -> [YuNetRawTensor]
}

/// Validates the YuNet input contract and canonicalizes raw Core ML outputs.
///
/// The facade is a value so callers can move it between concurrency domains.
/// The concrete Core ML driver is an actor, keeping its non-Sendable `MLModel`
/// and all SDK feature values isolated while prediction is in flight.
struct YuNetCoreMLRawInference: Sendable {
    private let driver: any YuNetCoreMLRawInferenceDriver

    init(driver: any YuNetCoreMLRawInferenceDriver) {
        self.driver = driver
    }

    init(
        model: sending MLModel
    ) throws(YuNetCoreMLRawInferenceError) {
        do {
            self.driver = try YuNetCoreMLModelDriver(model: model)
        } catch {
            throw .failed
        }
    }

    func predict(
        _ input: YuNetVImagePreprocessorOutput
    ) async throws -> [YuNetRawTensor] {
        try Task.checkCancellation()
        // This internal boundary is intentionally fail-closed: preprocessor
        // output values must remain finite bytes before entering Core ML.
        guard input.values.count == YuNetCoreMLRawInferenceContract.inputCount,
              input.values.allSatisfy({
                  $0.isFinite && (0...255).contains($0)
              }) else {
            throw YuNetCoreMLRawInferenceError.failed
        }

        do {
            let tensors = try await driver.predict(values: input.values)
            try Task.checkCancellation()
            return try Self.canonicalize(tensors)
        } catch let cancellation as CancellationError {
            // Caller cancellation is a control-flow signal, not an adapter
            // failure. Preserve the original error unchanged.
            throw cancellation
        } catch {
            // If cancellation races a generic driver failure, cancellation
            // wins and the SDK error remains private.
            if Task.isCancelled {
                throw CancellationError()
            }
            throw YuNetCoreMLRawInferenceError.failed
        }
    }

    private static func canonicalize(_ tensors: [YuNetRawTensor])
        throws(YuNetCoreMLRawInferenceError) -> [YuNetRawTensor] {
        guard tensors.count == YuNetCoreMLRawInferenceContract.outputSpecs.count
        else {
            throw .failed
        }

        var tensorsByName: [String: YuNetRawTensor] = [:]
        for tensor in tensors {
            guard YuNetCoreMLRawInferenceContract.outputSpecs.contains(where: {
                $0.name == tensor.name
            }),
                  tensorsByName[tensor.name] == nil else {
                throw .failed
            }
            tensorsByName[tensor.name] = tensor
        }

        var canonical: [YuNetRawTensor] = []
        canonical.reserveCapacity(YuNetCoreMLRawInferenceContract.outputSpecs.count)
        for spec in YuNetCoreMLRawInferenceContract.outputSpecs {
            guard let tensor = tensorsByName[spec.name],
                  tensor.shape == spec.shape,
                  tensor.values.count == spec.count,
                  tensor.values.allSatisfy(\.isFinite) else {
                throw .failed
            }
            canonical.append(tensor)
        }
        return canonical
    }
}

/// Actor-isolated Core ML bridge. Model loading and bundle policy stay outside
/// this slice; callers pass an already-loaded model through the `sending`
/// initializer.
actor YuNetCoreMLModelDriver: YuNetCoreMLRawInferenceDriver {
    private let model: MLModel

    init(
        model: sending MLModel
    ) throws(YuNetCoreMLRawInferenceError) {
        // Validate metadata once; each prediction validates the returned data.
        guard Self.validateModelDescription(model.modelDescription) else {
            throw .failed
        }
        self.model = model
    }

    func predict(values: [Float]) async throws -> [YuNetRawTensor] {
        do {
            let input = try Self.makeInput(values: values)
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                YuNetCoreMLRawInferenceContract.inputName:
                    MLFeatureValue(multiArray: input)
            ])
            let output = try await model.prediction(from: provider)
            guard output.featureNames == YuNetCoreMLRawInferenceContract.outputNames else {
                throw YuNetCoreMLRawInferenceError.failed
            }

            return try Self.copyOutputs(from: output)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw YuNetCoreMLRawInferenceError.failed
        }
    }

    private static func makeInput(values: [Float]) throws -> MLMultiArray {
        guard values.count == YuNetCoreMLRawInferenceContract.inputCount else {
            throw YuNetCoreMLRawInferenceError.failed
        }

        // Use the iOS 17 imported [NSNumber] initializer explicitly. The
        // [Int] shaped-array convenience is newer than this package's target.
        let shape = YuNetCoreMLRawInferenceContract.inputShape.map { NSNumber(value: $0) }
        let input = try MLMultiArray(shape: shape, dataType: .float32)
        try input.withUnsafeMutableBufferPointer(ofType: Float.self) {
            buffer,
            strides in
            guard strides == YuNetCoreMLRawInferenceContract.inputStrides,
                  buffer.count == values.count else {
                throw YuNetCoreMLRawInferenceError.failed
            }
            for index in values.indices {
                buffer[index] = values[index]
            }
        }
        return input
    }

    private static func copyOutputs(from provider: any MLFeatureProvider)
        throws -> [YuNetRawTensor] {
        try YuNetCoreMLRawInferenceContract.outputSpecs.map { spec in
            guard let feature = provider.featureValue(for: spec.name),
                  feature.type == .multiArray,
                  let array = feature.multiArrayValue else {
                throw YuNetCoreMLRawInferenceError.failed
            }
            return try copyOutput(named: spec.name, array: array)
        }
    }

    static func copyOutput(
        named name: String,
        array: MLMultiArray
    ) throws -> YuNetRawTensor {
        guard let spec = YuNetCoreMLRawInferenceContract.outputSpecs.first(where: {
            $0.name == name
        }) else {
            throw YuNetCoreMLRawInferenceError.failed
        }
        guard let shape = YuNetCoreMLRawInferenceContract.exactIntegers(array.shape),
              let strides = YuNetCoreMLRawInferenceContract.exactIntegers(array.strides),
              array.dataType == .float32,
              shape == spec.shape,
              strides.count == shape.count,
              strides.allSatisfy({ $0 > 0 }),
              array.count == spec.count else {
            throw YuNetCoreMLRawInferenceError.failed
        }

        var values = [Float]()
        try array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            guard let maxOffset = checkedMaximumOffset(
                shape: spec.shape,
                strides: strides,
                bufferCount: buffer.count
            ) else {
                throw YuNetCoreMLRawInferenceError.failed
            }

            values.reserveCapacity(spec.count)
            var batchOffset = 0
            for batch in 0..<spec.shape[0] {
                var cellOffset = batchOffset
                for cell in 0..<spec.shape[1] {
                    var channelOffset = cellOffset
                    for channel in 0..<spec.shape[2] {
                        guard channelOffset >= 0, channelOffset <= maxOffset else {
                            throw YuNetCoreMLRawInferenceError.failed
                        }
                        values.append(buffer[channelOffset])
                        if channel + 1 < spec.shape[2] {
                            guard let next = checkedAdd(channelOffset, strides[2]) else {
                                throw YuNetCoreMLRawInferenceError.failed
                            }
                            channelOffset = next
                        }
                    }
                    if cell + 1 < spec.shape[1] {
                        guard let next = checkedAdd(cellOffset, strides[1]) else {
                            throw YuNetCoreMLRawInferenceError.failed
                        }
                        cellOffset = next
                    }
                }
                if batch + 1 < spec.shape[0] {
                    guard let next = checkedAdd(batchOffset, strides[0]) else {
                        throw YuNetCoreMLRawInferenceError.failed
                    }
                    batchOffset = next
                }
            }
        }
        return YuNetRawTensor(name: spec.name, shape: spec.shape, values: values)
    }

    private static func checkedMaximumOffset(
        shape: [Int],
        strides: [Int],
        bufferCount: Int
    ) -> Int? {
        guard shape.count == 3, strides.count == 3, bufferCount > 0 else {
            return nil
        }

        var maximum = 0
        for index in shape.indices {
            guard shape[index] > 0, strides[index] > 0,
                  let term = checkedMultiply(strides[index], shape[index] - 1),
                  let next = checkedAdd(maximum, term) else {
                return nil
            }
            maximum = next
        }
        return maximum < bufferCount ? maximum : nil
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func validateModelDescription(_ model: MLModelDescription) -> Bool {
        let inputDescriptions = model.inputDescriptionsByName
        guard Set(inputDescriptions.keys) == [YuNetCoreMLRawInferenceContract.inputName],
              let input = inputDescriptions[YuNetCoreMLRawInferenceContract.inputName],
              input.type == .multiArray,
              let inputConstraint = input.multiArrayConstraint,
              YuNetCoreMLRawInferenceContract.exactIntegers(inputConstraint.shape)
                    == YuNetCoreMLRawInferenceContract.inputShape,
              inputConstraint.dataType == .float32 else {
            return false
        }

        let outputDescriptions = model.outputDescriptionsByName
        guard Set(outputDescriptions.keys) == YuNetCoreMLRawInferenceContract.outputNames
        else {
            return false
        }

        return YuNetCoreMLRawInferenceContract.outputSpecs.allSatisfy { spec in
            guard let output = outputDescriptions[spec.name],
                  output.type == .multiArray,
                  let constraint = output.multiArrayConstraint else {
                return false
            }
            return YuNetCoreMLRawInferenceContract.exactIntegers(constraint.shape) == spec.shape
                && constraint.dataType == .float32
        }
    }
}

/// One source of truth for the Core ML feature contract and graph order.
private enum YuNetCoreMLRawInferenceContract {
    static let targetDimension = YuNetLetterboxTransform.targetDimension
    static let inputName = "input"
    static let inputShape = [1, 3, targetDimension, targetDimension]
    static let inputCount = inputShape.reduce(1, *)
    static let inputStrides = [inputCount, targetDimension * targetDimension, targetDimension, 1]

    struct OutputSpec {
        let name: String
        let shape: [Int]

        var count: Int { shape.reduce(1, *) }
    }

    // Preserve the pinned converter's graph order. Core ML feature providers
    // expose a name set, so no dictionary order is ever relied upon.
    static let outputSpecs: [OutputSpec] = ["cls", "obj", "bbox", "kps"].flatMap { group in
        [8, 16, 32].map { stride in
            let cells = (targetDimension / stride) * (targetDimension / stride)
            let channels = group == "bbox" ? 4 : (group == "kps" ? 10 : 1)
            return OutputSpec(
                name: "\(group)_\(stride)",
                shape: [1, cells, channels]
            )
        }
    }

    static let outputNames = Set(outputSpecs.map(\.name))

    static func exactIntegers(_ values: [NSNumber]) -> [Int]? {
        var integers: [Int] = []
        integers.reserveCapacity(values.count)
        for value in values {
            guard value.doubleValue.isFinite,
                  let integer = Int(exactly: value) else {
                return nil
            }
            integers.append(integer)
        }
        return integers
    }
}
