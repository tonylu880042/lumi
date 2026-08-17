// Xcode 26 still imports Core ML without complete concurrency annotations.
// Keep the compatibility shim local: MLModel remains actor-isolated and no
// Core ML object crosses the Sendable driver boundary.
@preconcurrency import CoreML
import Foundation

/// Stable, payload-free failures at the SFace Core ML boundary.
enum SFaceCoreMLInferenceError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case failed

    var description: String { "SFace Core ML inference failed." }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}

/// Framework-free driver boundary used by the facade and deterministic tests.
protocol SFaceCoreMLInferenceDriver: Sendable {
    func predict(values: [Float]) async throws -> [Float]
}

/// Packs an aligned BGRA face, invokes SFace, and returns a normalized vector.
struct SFaceCoreMLInference: Sendable {
    static let modelVersion = "sface-opencv-zoo-4.10.0-fp32"

    private let driver: any SFaceCoreMLInferenceDriver

    init(driver: any SFaceCoreMLInferenceDriver) {
        self.driver = driver
    }

    init(
        model: sending MLModel
    ) throws(SFaceCoreMLInferenceError) {
        do {
            self.driver = try SFaceCoreMLModelDriver(model: model)
        } catch {
            throw .failed
        }
    }

    func embedding(
        for face: SFaceAlignedFace
    ) async throws -> FaceEmbedding {
        try Task.checkCancellation()

        do {
            let values = try Self.rgbNCHWValues(from: face)
            try Task.checkCancellation()
            let rawValues = try await driver.predict(values: values)
            try Task.checkCancellation()
            guard rawValues.count == SFaceCoreMLInferenceContract.outputCount,
                  rawValues.allSatisfy(\.isFinite) else {
                throw SFaceCoreMLInferenceError.failed
            }
            return try FaceEmbedding(
                modelVersion: Self.modelVersion,
                components: rawValues
            )
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            // Cancellation wins a race with a generic driver failure.
            if Task.isCancelled {
                throw CancellationError()
            }
            throw SFaceCoreMLInferenceError.failed
        }
    }

    private static func rgbNCHWValues(
        from face: SFaceAlignedFace
    ) throws(SFaceCoreMLInferenceError) -> [Float] {
        let width = SFaceAlignedFace.outputWidth
        let height = SFaceAlignedFace.outputHeight
        let bytesPerRow = SFaceAlignedFace.outputBytesPerRow
        let planeSize = width * height
        let expectedByteCount = bytesPerRow * height
        guard face.width == width, face.height == height,
              face.bytesPerRow == bytesPerRow,
              face.bytes.count == expectedByteCount else {
            throw .failed
        }

        var values = Array(
            repeating: Float.zero,
            count: SFaceCoreMLInferenceContract.inputCount
        )
        do {
            try face.bytes.withUnsafeBytes { rawBuffer in
                guard rawBuffer.baseAddress != nil,
                      rawBuffer.count == expectedByteCount else {
                    throw SFaceCoreMLInferenceError.failed
                }

                for y in 0..<height {
                    for x in 0..<width {
                        let pixelOffset = y * bytesPerRow + x * 4
                        let planeOffset = y * width + x
                        // Camera/SFaceAlignedFace bytes are BGRA; SFace's
                        // official OpenCV path sends RGB after swapRB=true.
                        values[planeOffset] = Float(rawBuffer[pixelOffset + 2])
                        values[planeSize + planeOffset] = Float(rawBuffer[pixelOffset + 1])
                        values[planeSize * 2 + planeOffset] = Float(rawBuffer[pixelOffset])
                    }
                }
            }
        } catch {
            throw .failed
        }

        return values
    }
}

/// Actor-isolated Core ML bridge. Model loading and bundle policy stay outside
/// this slice; callers pass an already-loaded model through `sending`.
actor SFaceCoreMLModelDriver: SFaceCoreMLInferenceDriver {
    private let model: MLModel

    init(
        model: sending MLModel
    ) throws(SFaceCoreMLInferenceError) {
        guard Self.validateModelDescription(model.modelDescription) else {
            throw .failed
        }
        self.model = model
    }

    func predict(values: [Float]) async throws -> [Float] {
        do {
            let input = try Self.makeInput(values: values)
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                SFaceCoreMLInferenceContract.inputName:
                    MLFeatureValue(multiArray: input)
            ])
            let output = try await model.prediction(from: provider)
            guard output.featureNames == SFaceCoreMLInferenceContract.outputNames,
                  let feature = output.featureValue(
                    for: SFaceCoreMLInferenceContract.outputName
                  ),
                  feature.type == .multiArray,
                  let array = feature.multiArrayValue else {
                throw SFaceCoreMLInferenceError.failed
            }
            return try Self.copyOutput(
                named: SFaceCoreMLInferenceContract.outputName,
                array: array
            )
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw SFaceCoreMLInferenceError.failed
        }
    }

    private static func makeInput(values: [Float]) throws -> MLMultiArray {
        guard values.count == SFaceCoreMLInferenceContract.inputCount else {
            throw SFaceCoreMLInferenceError.failed
        }

        let shape = SFaceCoreMLInferenceContract.inputShape.map {
            NSNumber(value: $0)
        }
        let input = try MLMultiArray(shape: shape, dataType: .float32)
        try input.withUnsafeMutableBufferPointer(ofType: Float.self) {
            buffer,
            strides in
            guard strides == SFaceCoreMLInferenceContract.inputStrides,
                  buffer.count == values.count else {
                throw SFaceCoreMLInferenceError.failed
            }
            for index in values.indices {
                buffer[index] = values[index]
            }
        }
        return input
    }

    /// Internal regression seam for logical Float32 output copying. Core ML
    /// arrays may expose positive padded strides; physical padding is ignored.
    static func copyOutput(
        named name: String,
        array: MLMultiArray
    ) throws(SFaceCoreMLInferenceError) -> [Float] {
        guard name == SFaceCoreMLInferenceContract.outputName,
              let shape = SFaceCoreMLInferenceContract.exactIntegers(array.shape),
              let strides = SFaceCoreMLInferenceContract.exactIntegers(array.strides),
              array.dataType == .float32,
              shape == SFaceCoreMLInferenceContract.outputShape,
              strides.count == shape.count,
              strides.allSatisfy({ $0 > 0 }),
              array.count == SFaceCoreMLInferenceContract.outputCount else {
            throw .failed
        }

        var values: [Float] = []
        do {
            try array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                guard let maxOffset = checkedMaximumOffset(
                    shape: shape,
                    strides: strides,
                    bufferCount: buffer.count
                ) else {
                    throw SFaceCoreMLInferenceError.failed
                }

                values.reserveCapacity(SFaceCoreMLInferenceContract.outputCount)
                var batchOffset = 0
                for batch in 0..<shape[0] {
                    var valueOffset = batchOffset
                    for value in 0..<shape[1] {
                        guard valueOffset >= 0, valueOffset <= maxOffset else {
                            throw SFaceCoreMLInferenceError.failed
                        }
                        values.append(buffer[valueOffset])
                        if value + 1 < shape[1] {
                            guard let next = checkedAdd(valueOffset, strides[1])
                            else {
                                throw SFaceCoreMLInferenceError.failed
                            }
                            valueOffset = next
                        }
                    }
                    if batch + 1 < shape[0] {
                        guard let next = checkedAdd(batchOffset, strides[0]) else {
                            throw SFaceCoreMLInferenceError.failed
                        }
                        batchOffset = next
                    }
                }
            }
        } catch let error as SFaceCoreMLInferenceError {
            throw error
        } catch {
            throw .failed
        }
        guard values.count == SFaceCoreMLInferenceContract.outputCount,
              values.allSatisfy(\.isFinite) else {
            throw .failed
        }
        return values
    }

    private static func checkedMaximumOffset(
        shape: [Int],
        strides: [Int],
        bufferCount: Int
    ) -> Int? {
        guard shape.count == 2, strides.count == 2, bufferCount > 0 else {
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
        let inputs = model.inputDescriptionsByName
        guard Set(inputs.keys) == SFaceCoreMLInferenceContract.inputNames,
              let input = inputs[SFaceCoreMLInferenceContract.inputName],
              input.type == .multiArray,
              let inputConstraint = input.multiArrayConstraint,
              SFaceCoreMLInferenceContract.exactIntegers(inputConstraint.shape)
                == SFaceCoreMLInferenceContract.inputShape,
              inputConstraint.dataType == .float32 else {
            return false
        }

        let outputs = model.outputDescriptionsByName
        guard Set(outputs.keys) == SFaceCoreMLInferenceContract.outputNames,
              let output = outputs[SFaceCoreMLInferenceContract.outputName],
              output.type == .multiArray,
              let outputConstraint = output.multiArrayConstraint else {
            return false
        }
        return SFaceCoreMLInferenceContract.exactIntegers(outputConstraint.shape)
                == SFaceCoreMLInferenceContract.outputShape
            && outputConstraint.dataType == .float32
    }
}

private enum SFaceCoreMLInferenceContract {
    static let inputName = "data"
    static let inputNames = Set([inputName])
    static let inputShape = [1, 3, 112, 112]
    static let inputCount = inputShape.reduce(1, *)
    static let inputStrides = [inputCount, 112 * 112, 112, 1]

    static let outputName = "embedding"
    static let outputNames = Set([outputName])
    static let outputShape = [1, 128]
    static let outputCount = outputShape.reduce(1, *)

    static func exactIntegers(_ values: [NSNumber]) -> [Int]? {
        var integers: [Int] = []
        integers.reserveCapacity(values.count)
        for value in values {
            guard value.doubleValue.isFinite,
                  let integer = Int(exactly: value),
                  Double(integer) == value.doubleValue else {
                return nil
            }
            integers.append(integer)
        }
        return integers
    }
}
