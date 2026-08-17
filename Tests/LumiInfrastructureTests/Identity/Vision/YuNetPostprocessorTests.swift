import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("YuNet postprocessor")
struct YuNetPostprocessorTests {
    @Test("validates configuration boundaries and redacts every error")
    func validatesConfigurationAndRedactsErrors() throws {
        let defaults = YuNetPostprocessingConfiguration.validationDefault
        #expect(defaults.scoreThreshold == 0.9)
        #expect(defaults.nmsIOUThreshold == 0.3)
        #expect(defaults.preNMSTopK == 5_000)

        let custom = try YuNetPostprocessingConfiguration(
            scoreThreshold: 0,
            nmsIOUThreshold: 1,
            preNMSTopK: 1
        )
        #expect(custom.scoreThreshold == 0)
        #expect(custom.nmsIOUThreshold == 1)
        #expect(custom.preNMSTopK == 1)

        for invalid in [
            (score: Float.nan, nms: Float(0.3), topK: 1),
            (score: Float.infinity, nms: Float(0.3), topK: 1),
            (score: Float(-0.1), nms: Float(0.3), topK: 1),
            (score: Float(1.1), nms: Float(0.3), topK: 1),
            (score: Float(0.9), nms: Float.nan, topK: 1),
            (score: Float(0.9), nms: Float.infinity, topK: 1),
            (score: Float(0.9), nms: Float(-0.1), topK: 1),
            (score: Float(0.9), nms: Float(1.1), topK: 1),
            (score: Float(0.9), nms: Float(0.3), topK: 0),
            (score: Float(0.9), nms: Float(0.3), topK: -1)
        ] {
            #expect(throws: YuNetPostprocessorError.invalidConfiguration) {
                try YuNetPostprocessingConfiguration(
                    scoreThreshold: invalid.score,
                    nmsIOUThreshold: invalid.nms,
                    preNMSTopK: invalid.topK
                )
            }
        }

        let errors: [YuNetPostprocessorError] = [
            .invalidConfiguration,
            .malformedRawOutputs,
            .nonFiniteRawValue,
            .numericOverflow,
            .invalidGeometry
        ]
        let descriptions = errors.map { String(describing: $0) }
        let debugDescriptions = errors.map { String(reflecting: $0) }
        #expect(Set(descriptions).count == 1)
        #expect(Set(debugDescriptions).count == 1)
        for error in errors {
            #expect(Mirror(reflecting: error).children.isEmpty)
            #expect(!String(describing: error).contains("0.9"))
            #expect(!String(reflecting: error).contains("raw"))
        }
    }

    @Test("canonicalizes exactly twelve tensor names, shapes, and values")
    func canonicalizesExactTensorAggregate() throws {
        let candidate = SyntheticCandidate(
            stride: 8,
            cell: 0,
            classification: 0.95,
            objectness: 0.95,
            bbox: [2, 2, 0, 0],
            landmarks: Array(repeating: 0.5, count: 10)
        )
        let reversed = makeRawTensors(
            candidates: [candidate],
            namesOrder: Array(Self.outputNames.reversed())
        )
        let processor = try makeProcessor()

        let faces = try processor.process(reversed)

        #expect(faces.count == 1)
        #expect(abs(faces[0].confidence - 0.95) < 0.000_001)

        var malformed = reversed
        malformed[0] = YuNetRawTensor(
            name: "unexpected",
            shape: [1, 1, 1],
            values: [0]
        )
        #expect(throws: YuNetPostprocessorError.malformedRawOutputs) {
            try processor.process(malformed)
        }

        malformed = reversed
        malformed[0] = YuNetRawTensor(
            name: "cls_8",
            shape: [1, 6_399, 1],
            values: Array(repeating: 0, count: 6_399)
        )
        #expect(throws: YuNetPostprocessorError.malformedRawOutputs) {
            try processor.process(malformed)
        }

        malformed = reversed
        malformed[0] = YuNetRawTensor(
            name: "cls_8",
            shape: [1, 6_400, 1],
            values: Array(repeating: 0, count: 6_400)
        )
        #expect(throws: YuNetPostprocessorError.malformedRawOutputs) {
            try processor.process(malformed)
        }

        #expect(throws: YuNetPostprocessorError.malformedRawOutputs) {
            try processor.process(Array(reversed.dropLast()))
        }

        malformed = reversed
        malformed[0] = YuNetRawTensor(
            name: "extra",
            shape: [1, 6_400, 1],
            values: Array(repeating: 0, count: 6_400)
        )
        #expect(throws: YuNetPostprocessorError.malformedRawOutputs) {
            try processor.process(malformed)
        }

        malformed = reversed
        let kpsIndex = try #require(reversed.firstIndex { $0.name == "kps_32" })
        malformed[kpsIndex] = YuNetRawTensor(
            name: "kps_32",
            shape: [1, 400, 10],
            values: Array(repeating: 0, count: 3_999)
        )
        #expect(throws: YuNetPostprocessorError.malformedRawOutputs) {
            try processor.process(malformed)
        }
    }

    @Test("keeps singleton equality, excludes multi-candidate equality, and filters below threshold")
    func appliesThresholdBoundaries() throws {
        let processor = try makeProcessor()
        #expect(try processor.process(makeRawTensors(candidates: [])).isEmpty)

        let below = candidate(score: 0.8, cell: 0)
        #expect(try processor.process(makeRawTensors(candidates: [below])).isEmpty)

        let equality = candidate(score: 0.9, cell: 0)
        let singleton = try processor.process(makeRawTensors(candidates: [equality]))
        #expect(singleton.count == 1)
        #expect(abs(singleton[0].confidence - 0.9) < 0.000_001)

        let secondEquality = candidate(score: 0.9, cell: 1)
        #expect(
            try processor.process(
                makeRawTensors(candidates: [equality, secondEquality])
            ).isEmpty
        )
    }

    @Test("decodes stride geometry and five SFace landmarks into lower-left space")
    func decodesStrideGeometryAndLandmarks() throws {
        let candidate = SyntheticCandidate(
            stride: 16,
            cell: 2 * 40 + 3,
            classification: 0.95,
            objectness: 0.95,
            bbox: [2, 3, Float(log(2.0)), Float(log(3.0))],
            landmarks: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        )
        let processor = try makeProcessor()
        let face = try #require(
            processor.process(makeRawTensors(candidates: [candidate])).first
        )

        #expect(abs(face.boundingBox.x - 0.1) < 0.000_000_1)
        #expect(abs(face.boundingBox.y - 0.8375) < 0.000_000_1)
        #expect(abs(face.boundingBox.width - 0.05) < 0.000_000_1)
        #expect(abs(face.boundingBox.height - 0.075) < 0.000_000_1)

        let landmarks = try #require(face.alignmentLandmarks)
        let expected: [SFaceAlignmentLandmarkRole: (Double, Double)] = [
            .subjectRightEye: (0.1, 0.9),
            .subjectLeftEye: (0.15, 0.85),
            .noseTip: (0.2, 0.8),
            .subjectRightMouthCorner: (0.25, 0.75),
            .subjectLeftMouthCorner: (0.3, 0.7)
        ]
        for role in SFaceAlignmentLandmarkRole.allCases {
            let point = landmarks[role]
            let expectedPoint = try #require(expected[role])
            #expect(abs(point.x - expectedPoint.0) < 0.000_000_1)
            #expect(abs(point.y - expectedPoint.1) < 0.000_000_1)
        }
    }

    @Test("clamps classification and objectness before score calculation")
    func clampsScoreInputs() throws {
        let processor = try makeProcessor()
        let clamped = SyntheticCandidate(
            stride: 8,
            cell: 0,
            classification: 1.5,
            objectness: 2,
            bbox: [2, 2, 0, 0],
            landmarks: Array(repeating: 0.5, count: 10)
        )

        let face = try #require(
            processor.process(makeRawTensors(candidates: [clamped])).first
        )
        #expect(face.confidence == 1)

        let clampedToZero = SyntheticCandidate(
            stride: 8,
            cell: 1,
            classification: -1,
            objectness: 1.5,
            bbox: [2, 2, 0, 0],
            landmarks: Array(repeating: 0.5, count: 10)
        )
        #expect(try processor.process(makeRawTensors(candidates: [clampedToZero])).isEmpty)
    }

    @Test("fails closed for non-finite values, exp overflow, and invalid geometry")
    func rejectsNonFiniteOverflowAndGeometry() throws {
        let processor = try makeProcessor()
        var nonFinite = makeRawTensors(candidates: [])
        let clsIndex = try #require(nonFinite.firstIndex { $0.name == "cls_8" })
        nonFinite[clsIndex] = YuNetRawTensor(
            name: "cls_8",
            shape: [1, 6_400, 1],
            values: [Float.nan] + Array(repeating: 0, count: 6_399)
        )
        #expect(throws: YuNetPostprocessorError.nonFiniteRawValue) {
            try processor.process(nonFinite)
        }

        let overflow = SyntheticCandidate(
            stride: 8,
            cell: 0,
            classification: 0.95,
            objectness: 0.95,
            bbox: [2, 2, Float.greatestFiniteMagnitude, 0],
            landmarks: Array(repeating: 0.5, count: 10)
        )
        #expect(throws: YuNetPostprocessorError.numericOverflow) {
            try processor.process(makeRawTensors(candidates: [overflow]))
        }

        let outOfFrame = SyntheticCandidate(
            stride: 8,
            cell: 0,
            classification: 0.95,
            objectness: 0.95,
            bbox: [100, 100, 0, 0],
            landmarks: Array(repeating: 0.5, count: 10)
        )
        #expect(throws: YuNetPostprocessorError.invalidGeometry) {
            try processor.process(makeRawTensors(candidates: [outOfFrame]))
        }
    }

    @Test("fails closed before strict NMS filtering can hide invalid candidates")
    func validatesEveryInitialCandidateBeforeFiltering() throws {
        let valid = SyntheticCandidate(
            stride: 8,
            cell: 0,
            classification: 0.95,
            objectness: 0.95,
            bbox: [2, 2, 0, 0],
            landmarks: Array(repeating: 0.5, count: 10)
        )
        let equalityWithOverflow = SyntheticCandidate(
            stride: 8,
            cell: 1,
            classification: 0.9,
            objectness: 0.9,
            bbox: [2, 2, Float.greatestFiniteMagnitude, 0],
            landmarks: Array(repeating: 0.5, count: 10)
        )
        let processor = try makeProcessor(
            scoreThreshold: 0.9,
            nmsIOUThreshold: 0.3,
            preNMSTopK: 1
        )

        #expect(throws: YuNetPostprocessorError.numericOverflow) {
            try processor.process(
                makeRawTensors(candidates: [valid, equalityWithOverflow])
            )
        }
    }

    @Test("sorts stable score ties and applies pre-NMS top-K")
    func stableTiesAndTopK() throws {
        let first = nmsCandidate(cell: 0, score: 0.8, xOffset: 2.1)
        let second = nmsCandidate(cell: 1, score: 0.8, xOffset: 1.1)
        let processor = try makeProcessor(
            scoreThreshold: 0.5,
            nmsIOUThreshold: 0.3,
            preNMSTopK: 1
        )

        let faces = try processor.process(makeRawTensors(candidates: [first, second]))

        #expect(faces.count == 1)
        #expect(abs(faces[0].boundingBox.x - 0.00125) < 0.000_01)
    }

    @Test("uses integer-truncated Rect2i IoU and keeps equality at NMS threshold")
    func integerNMSAndStrictEquality() throws {
        let widthOffset = Float(log(1.3625))
        let first = SyntheticCandidate(
            stride: 8,
            cell: 0,
            classification: 0.9,
            objectness: 0.9,
            bbox: [0.79375, 2, widthOffset, 0],
            landmarks: Array(repeating: 0.5, count: 10)
        )
        let second = SyntheticCandidate(
            stride: 8,
            cell: 1,
            classification: 0.8,
            objectness: 0.8,
            bbox: [0.19375, 2, widthOffset, 0],
            landmarks: Array(repeating: 0.5, count: 10)
        )

        let suppressing = try makeProcessor(
            scoreThreshold: 0.5,
            nmsIOUThreshold: 0.5,
            preNMSTopK: 5_000
        )
        #expect(
            try suppressing.process(makeRawTensors(candidates: [first, second])).count == 2
        )

        let touchingSecond = SyntheticCandidate(
            stride: 8,
            cell: 1,
            classification: 0.8,
            objectness: 0.8,
            bbox: [0.94375, 2, widthOffset, 0],
            landmarks: Array(repeating: 0.5, count: 10)
        )
        let equality = try makeProcessor(
            scoreThreshold: 0.5,
            nmsIOUThreshold: 0,
            preNMSTopK: 5_000
        )
        #expect(
            try equality.process(
                makeRawTensors(candidates: [first, touchingSecond])
            ).count == 2
        )
    }

    @Test("configuration, tensors, processor, and faces are Sendable")
    func valuesAreSendable() throws {
        let configuration = YuNetPostprocessingConfiguration.validationDefault
        let processor = try YuNetPostprocessor(configuration: configuration)
        let tensors = makeRawTensors(candidates: [])
        let faces = try processor.process(tensors)

        acceptsSendable(configuration)
        acceptsSendable(processor)
        acceptsSendable(tensors[0])
        acceptsSendable(faces)
    }

    private static let outputNames = [
        "cls_8", "cls_16", "cls_32",
        "obj_8", "obj_16", "obj_32",
        "bbox_8", "bbox_16", "bbox_32",
        "kps_8", "kps_16", "kps_32"
    ]

    private struct SyntheticCandidate {
        let stride: Int
        let cell: Int
        let classification: Float
        let objectness: Float
        let bbox: [Float]
        let landmarks: [Float]
    }

    private func makeProcessor(
        scoreThreshold: Float = 0.9,
        nmsIOUThreshold: Float = 0.3,
        preNMSTopK: Int = 5_000
    ) throws -> YuNetPostprocessor {
        let configuration = try YuNetPostprocessingConfiguration(
            scoreThreshold: scoreThreshold,
            nmsIOUThreshold: nmsIOUThreshold,
            preNMSTopK: preNMSTopK
        )
        return try YuNetPostprocessor(configuration: configuration)
    }

    private func candidate(score: Float, cell: Int) -> SyntheticCandidate {
        SyntheticCandidate(
            stride: 8,
            cell: cell,
            classification: score,
            objectness: score,
            bbox: [2, 2, 0, 0],
            landmarks: Array(repeating: 0.5, count: 10)
        )
    }

    private func nmsCandidate(
        cell: Int,
        score: Float,
        xOffset: Float
    ) -> SyntheticCandidate {
        SyntheticCandidate(
            stride: 8,
            cell: cell,
            classification: score,
            objectness: score,
            bbox: [xOffset, 2.1, Float(log(4.0)), Float(log(4.0))],
            landmarks: Array(repeating: 0.5, count: 10)
        )
    }

    private func makeRawTensors(
        candidates: [SyntheticCandidate],
        namesOrder: [String] = Self.outputNames
    ) -> [YuNetRawTensor] {
        let specs = Self.outputNames.map { name -> (String, [Int]) in
            let parts = name.split(separator: "_")
            let group = parts[0]
            let stride = Int(parts[1])!
            let cells = (640 / stride) * (640 / stride)
            let channels = group == "bbox" ? 4 : (group == "kps" ? 10 : 1)
            return (name, [1, cells, channels])
        }
        var valuesByName = Dictionary(
            uniqueKeysWithValues: specs.map { name, shape in
                (name, Array(repeating: Float.zero, count: shape.reduce(1, *)))
            }
        )

        for candidate in candidates {
            let prefix = String(candidate.stride)
            let cell = candidate.cell
            valuesByName["cls_\(prefix)"]![cell] = candidate.classification
            valuesByName["obj_\(prefix)"]![cell] = candidate.objectness
            valuesByName["bbox_\(prefix)"]!.replaceSubrange(
                (cell * 4)..<(cell * 4 + 4),
                with: candidate.bbox
            )
            valuesByName["kps_\(prefix)" ]!.replaceSubrange(
                (cell * 10)..<(cell * 10 + 10),
                with: candidate.landmarks
            )
        }

        return namesOrder.map { name in
            let shape = specs.first { $0.0 == name }!.1
            return YuNetRawTensor(name: name, shape: shape, values: valuesByName[name]!)
        }
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
