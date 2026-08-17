import Foundation
import CoreML
@testable import LumiInfrastructure
import Testing

@Suite("YuNet Core ML raw inference")
struct YuNetCoreMLRawInferenceTests {
    @Test("returns exactly twelve tensors in canonical graph order")
    func canonicalizesRawOutputs() async throws {
        let input = try makeInput()
        let expected = makeRawTensors()
        let driver = RecordingDriver(outputs: Array(expected.reversed()))
        let inference = YuNetCoreMLRawInference(driver: driver)

        let tensors = try await inference.predict(input)

        #expect(tensors == expected)
        #expect(await driver.receivedValues == input.values)
        #expect(await driver.callCount == 1)
    }

    @Test("rejects an input that is not the exact YuNet tensor size")
    func rejectsWrongInputCount() async throws {
        let transform = try makeTransform()
        let values = Array(repeating: Float(1), count: Self.inputCount - 1)
        let input = YuNetVImagePreprocessorOutput(
            values: values,
            transform: transform
        )
        let driver = RecordingDriver(outputs: makeRawTensors())
        let inference = YuNetCoreMLRawInference(driver: driver)

        await #expect(throws: YuNetCoreMLRawInferenceError.failed) {
            _ = try await inference.predict(input)
        }
        #expect(await driver.callCount == 0)
    }

    @Test("rejects non-finite and out-of-range input values")
    func rejectsInvalidInputValues() async throws {
        let transform = try makeTransform()
        let invalidValues: [Float] = [.nan, .infinity, -.infinity, -0.001, 255.001]

        for invalidValue in invalidValues {
            var values = Array(repeating: Float(1), count: Self.inputCount)
            values[0] = invalidValue
            let input = YuNetVImagePreprocessorOutput(
                values: values,
                transform: transform
            )
            let driver = RecordingDriver(outputs: makeRawTensors())
            let inference = YuNetCoreMLRawInference(driver: driver)

            await #expect(throws: YuNetCoreMLRawInferenceError.failed) {
                _ = try await inference.predict(input)
            }
            #expect(await driver.callCount == 0)
        }
    }

    @Test("rejects missing, extra, duplicate, malformed, and non-finite outputs")
    func rejectsMalformedOutputs() async throws {
        let input = try makeInput()
        let valid = makeRawTensors()
        let malformedOutputs: [[YuNetRawTensor]] = [
            Array(valid.dropLast()),
            valid + [YuNetRawTensor(name: "extra", shape: [1, 1, 1], values: [0])],
            [valid[0]] + valid,
            replacing(valid, at: 0, with: YuNetRawTensor(
                name: "unknown",
                shape: valid[0].shape,
                values: valid[0].values
            )),
            replacing(valid, at: 1, with: YuNetRawTensor(
                name: valid[0].name,
                shape: valid[1].shape,
                values: valid[1].values
            )),
            replacing(valid, at: 0, with: YuNetRawTensor(
                name: valid[0].name,
                shape: [1, 1, 1],
                values: [0]
            )),
            replacing(valid, at: 0, with: YuNetRawTensor(
                name: valid[0].name,
                shape: valid[0].shape,
                values: Array(valid[0].values.dropLast())
            )),
            replacing(valid, at: 0, with: YuNetRawTensor(
                name: valid[0].name,
                shape: valid[0].shape,
                values: [Float.nan] + Array(valid[0].values.dropFirst())
            ))
        ]

        for malformed in malformedOutputs {
            let driver = RecordingDriver(outputs: malformed)
            let inference = YuNetCoreMLRawInference(driver: driver)

            await #expect(throws: YuNetCoreMLRawInferenceError.failed) {
                _ = try await inference.predict(input)
            }
        }
    }

    @Test("pre-cancellation does not call the driver")
    func rejectsPreCancellationBeforeDriver() async throws {
        let driver = RecordingDriver(outputs: makeRawTensors())
        let inference = YuNetCoreMLRawInference(driver: driver)
        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            _ = try await inference.predict(makeInput())
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await driver.callCount == 0)
    }

    @Test("redacts generic driver failures to one fixed error")
    func redactsDriverFailure() async throws {
        let input = try makeInput()
        let driver = FailingDriver()
        let inference = YuNetCoreMLRawInference(driver: driver)

        do {
            _ = try await inference.predict(input)
            Issue.record("expected driver failure")
        } catch let error as YuNetCoreMLRawInferenceError {
            #expect(error == .failed)
            #expect(String(describing: error) == "YuNet Core ML raw inference failed.")
            #expect(String(reflecting: error) == "YuNet Core ML raw inference failed.")
            #expect(Mirror(reflecting: error).children.isEmpty)
            #expect(!String(reflecting: error).contains(FailingDriver.marker))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("preserves direct driver cancellation")
    func preservesDirectCancellation() async throws {
        let input = try makeInput()
        let inference = YuNetCoreMLRawInference(driver: CancellationDriver())

        await #expect(throws: CancellationError.self) {
            _ = try await inference.predict(input)
        }
    }

    @Test("preserves caller cancellation while driver is suspended")
    func preservesCallerCancellation() async throws {
        let driver = SuspendedDriver()
        let inference = YuNetCoreMLRawInference(driver: driver)
        let task = Task {
            _ = try await inference.predict(makeInput())
        }

        await driver.waitForStart()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("caller cancellation wins when driver throws a generic failure")
    func cancellationWinsGenericDriverFailure() async throws {
        let driver = GenericFailureAfterCancellationDriver()
        let inference = YuNetCoreMLRawInference(driver: driver)
        let task = Task {
            _ = try await inference.predict(makeInput())
        }

        await driver.waitForStart()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("keeps the facade, error, and tensors Sendable")
    func valuesAreSendable() throws {
        let inference = YuNetCoreMLRawInference(
            driver: RecordingDriver(outputs: makeRawTensors())
        )
        acceptsSendable(inference)
        acceptsSendable(YuNetCoreMLRawInferenceError.failed)
        acceptsSendable(makeRawTensors()[0])
    }

    @Test("copies logical values from padded kps output strides")
    func copiesPaddedKPSOutput() throws {
        let array = try makePaddedKPSArray()

        let tensor = try YuNetCoreMLModelDriver.copyOutput(
            named: "kps_8",
            array: array
        )

        #expect(tensor.shape == [1, 6_400, 10])
        #expect(tensor.values == (0..<64_000).map(Float.init))
    }

    private static let inputCount = 1_228_800

    private struct OutputFixture {
        let name: String
        let shape: [Int]
    }

    private static let outputFixtures = [
        OutputFixture(name: "cls_8", shape: [1, 6_400, 1]),
        OutputFixture(name: "cls_16", shape: [1, 1_600, 1]),
        OutputFixture(name: "cls_32", shape: [1, 400, 1]),
        OutputFixture(name: "obj_8", shape: [1, 6_400, 1]),
        OutputFixture(name: "obj_16", shape: [1, 1_600, 1]),
        OutputFixture(name: "obj_32", shape: [1, 400, 1]),
        OutputFixture(name: "bbox_8", shape: [1, 6_400, 4]),
        OutputFixture(name: "bbox_16", shape: [1, 1_600, 4]),
        OutputFixture(name: "bbox_32", shape: [1, 400, 4]),
        OutputFixture(name: "kps_8", shape: [1, 6_400, 10]),
        OutputFixture(name: "kps_16", shape: [1, 1_600, 10]),
        OutputFixture(name: "kps_32", shape: [1, 400, 10])
    ]

    private func makeTransform() throws -> YuNetLetterboxTransform {
        try YuNetLetterboxTransform(sourceWidth: 3, sourceHeight: 2)
    }

    private func makeInput() throws -> YuNetVImagePreprocessorOutput {
        var values = Array(repeating: Float(1), count: Self.inputCount)
        values[0] = 0
        values[1] = 255
        values[Self.inputCount - 1] = 127.5
        return YuNetVImagePreprocessorOutput(
            values: values,
            transform: try makeTransform()
        )
    }

    private func makeRawTensors() -> [YuNetRawTensor] {
        Self.outputFixtures.map { fixture in
            let count = fixture.shape.reduce(1, *)
            let values = (0..<count).map { Float($0) / 100 }
            return YuNetRawTensor(
                name: fixture.name,
                shape: fixture.shape,
                values: values
            )
        }
    }

    private func makePaddedKPSArray() throws -> MLMultiArray {
        let physicalCount = 102_400
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: physicalCount)
        for index in 0..<physicalCount {
            buffer[index] = -999
        }
        for cell in 0..<6_400 {
            for channel in 0..<10 {
                buffer[cell * 16 + channel] = Float(cell * 10 + channel)
            }
        }

        return try MLMultiArray(
            dataPointer: UnsafeMutableRawPointer(buffer),
            shape: [1, 6_400, 10],
            dataType: .float32,
            strides: [102_400, 16, 1],
            deallocator: { pointer in
                pointer.assumingMemoryBound(to: Float.self).deallocate()
            }
        )
    }

    private func replacing(
        _ tensors: [YuNetRawTensor],
        at index: Int,
        with replacement: YuNetRawTensor
    ) -> [YuNetRawTensor] {
        var copy = tensors
        copy[index] = replacement
        return copy
    }
}

private actor RecordingDriver: YuNetCoreMLRawInferenceDriver {
    private let outputs: [YuNetRawTensor]
    private(set) var receivedValues: [Float]?
    private(set) var callCount = 0

    init(outputs: [YuNetRawTensor]) {
        self.outputs = outputs
    }

    func predict(values: [Float]) async throws -> [YuNetRawTensor] {
        callCount += 1
        receivedValues = values
        return outputs
    }
}

private actor FailingDriver: YuNetCoreMLRawInferenceDriver {
    static let marker = "coreml-driver-secret-marker"

    func predict(values: [Float]) async throws -> [YuNetRawTensor] {
        _ = values
        struct InjectedFailure: Error {
            let marker: String
        }
        throw InjectedFailure(marker: Self.marker)
    }
}

private actor CancellationDriver: YuNetCoreMLRawInferenceDriver {
    func predict(values: [Float]) async throws -> [YuNetRawTensor] {
        _ = values
        throw CancellationError()
    }
}

private actor SuspendedDriver: YuNetCoreMLRawInferenceDriver {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false
    private var resultContinuation: CheckedContinuation<[YuNetRawTensor], Error>?

    func predict(values: [Float]) async throws -> [YuNetRawTensor] {
        _ = values
        started = true
        startWaiter?.resume()
        startWaiter = nil

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[YuNetRawTensor], Error>) in
                if cancellationRequested {
                    continuation.resume(throwing: CancellationError())
                } else {
                    resultContinuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWithCancellationError() }
        })
    }

    func waitForStart() async {
        if started { return }

        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    private func cancelWithCancellationError() {
        cancellationRequested = true
        resultContinuation?.resume(throwing: CancellationError())
        resultContinuation = nil
    }
}

private actor GenericFailureAfterCancellationDriver: YuNetCoreMLRawInferenceDriver {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false
    private var resultContinuation: CheckedContinuation<[YuNetRawTensor], Error>?

    func predict(values: [Float]) async throws -> [YuNetRawTensor] {
        _ = values
        started = true
        startWaiter?.resume()
        startWaiter = nil

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[YuNetRawTensor], Error>) in
                if cancellationRequested {
                    continuation.resume(throwing: GenericFailure())
                } else {
                    resultContinuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWithGenericFailure() }
        })
    }

    func waitForStart() async {
        if started { return }

        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    private func cancelWithGenericFailure() {
        cancellationRequested = true
        resultContinuation?.resume(throwing: GenericFailure())
        resultContinuation = nil
    }

    private struct GenericFailure: Error {}
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
