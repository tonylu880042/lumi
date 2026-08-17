import Foundation

enum YuNetPostprocessorError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case invalidConfiguration
    case malformedRawOutputs
    case nonFiniteRawValue
    case numericOverflow
    case invalidGeometry

    var description: String { "YuNet post-processing failed." }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

struct YuNetPostprocessingConfiguration: Equatable, Sendable {
    let scoreThreshold: Float
    let nmsIOUThreshold: Float
    let preNMSTopK: Int

    static let validationDefault = try! Self(
        scoreThreshold: 0.9,
        nmsIOUThreshold: 0.3,
        preNMSTopK: 5_000
    )

    init(
        scoreThreshold: Float,
        nmsIOUThreshold: Float,
        preNMSTopK: Int
    ) throws(YuNetPostprocessorError) {
        guard scoreThreshold.isFinite, (0...1).contains(scoreThreshold),
              nmsIOUThreshold.isFinite, (0...1).contains(nmsIOUThreshold),
              preNMSTopK > 0 else {
            throw .invalidConfiguration
        }
        self.scoreThreshold = scoreThreshold
        self.nmsIOUThreshold = nmsIOUThreshold
        self.preNMSTopK = preNMSTopK
    }
}

struct YuNetRawTensor: Equatable, Sendable {
    let name: String
    let shape: [Int]
    let values: [Float]

    init(name: String, shape: [Int], values: [Float]) {
        self.name = name
        self.shape = shape
        self.values = values
    }
}

struct YuNetPostprocessor: Sendable {
    private let configuration: YuNetPostprocessingConfiguration

    init(configuration: YuNetPostprocessingConfiguration = .validationDefault) throws {
        self.configuration = try YuNetPostprocessingConfiguration(
            scoreThreshold: configuration.scoreThreshold,
            nmsIOUThreshold: configuration.nmsIOUThreshold,
            preNMSTopK: configuration.preNMSTopK
        )
    }

    func process(
        _ tensors: [YuNetRawTensor]
    ) throws(YuNetPostprocessorError) -> [DetectedFace] {
        let outputs = try canonicalize(tensors)
        var candidates: [Candidate] = []
        var decodeOrder = 0

        for stride in [8, 16, 32] {
            let columns = 640 / stride
            let cls = outputs["cls_\(stride)"]!.values
            let obj = outputs["obj_\(stride)"]!.values
            let bbox = outputs["bbox_\(stride)"]!.values
            let kps = outputs["kps_\(stride)"]!.values

            for row in 0..<columns {
                for column in 0..<columns {
                    let cell = row * columns + column
                    let classification = min(1, max(0, cls[cell]))
                    let objectness = min(1, max(0, obj[cell]))
                    let score = sqrt(classification * objectness)
                    guard score.isFinite else { throw .numericOverflow }
                    if score >= configuration.scoreThreshold {
                        let bboxStart = cell * 4
                        let landmarkStart = cell * 10
                        candidates.append(Candidate(
                            score: score,
                            order: decodeOrder,
                            stride: stride,
                            row: row,
                            column: column,
                            bbox: Array(bbox[bboxStart..<(bboxStart + 4)]),
                            landmarks: Array(kps[landmarkStart..<(landmarkStart + 10)])
                        ))
                    }
                    decodeOrder += 1
                }
            }
        }

        guard !candidates.isEmpty else { return [] }
        let decoded = try candidates.map(decode)
        if decoded.count == 1 {
            return [decoded[0].face]
        }

        let filtered = decoded
            .filter { $0.candidate.score > configuration.scoreThreshold }
            .sorted {
                $0.candidate.score == $1.candidate.score
                    ? $0.candidate.order < $1.candidate.order
                    : $0.candidate.score > $1.candidate.score
            }
            .prefix(configuration.preNMSTopK)

        var kept: [(face: DetectedFace, rect: IntegerRect)] = []
        for candidate in filtered {
            let rect = try integerRect(from: candidate)
            if kept.allSatisfy({
                intersectionOverUnion(rect, $0.rect)
                    <= Double(configuration.nmsIOUThreshold)
            }) {
                kept.append((candidate.face, rect))
            }
        }
        return kept.map(\.face)
    }

    private struct Candidate {
        let score: Float
        let order: Int
        let stride: Int
        let row: Int
        let column: Int
        let bbox: [Float]
        let landmarks: [Float]
    }

    private struct IntegerRect {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    private struct DecodedCandidate {
        let candidate: Candidate
        let face: DetectedFace
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private struct OutputSpec {
        let name: String
        let shape: [Int]
    }

    private static let outputSpecs: [OutputSpec] = {
        [8, 16, 32].flatMap { stride in
            let cells = (640 / stride) * (640 / stride)
            return [
                OutputSpec(name: "cls_\(stride)", shape: [1, cells, 1]),
                OutputSpec(name: "obj_\(stride)", shape: [1, cells, 1]),
                OutputSpec(name: "bbox_\(stride)", shape: [1, cells, 4]),
                OutputSpec(name: "kps_\(stride)", shape: [1, cells, 10])
            ]
        }
    }()

    private func canonicalize(
        _ tensors: [YuNetRawTensor]
    ) throws(YuNetPostprocessorError) -> [String: YuNetRawTensor] {
        guard tensors.count == Self.outputSpecs.count else {
            throw .malformedRawOutputs
        }

        var outputs: [String: YuNetRawTensor] = [:]
        for tensor in tensors {
            guard Self.outputSpecs.contains(where: { $0.name == tensor.name }),
                  outputs[tensor.name] == nil else {
                throw .malformedRawOutputs
            }
            outputs[tensor.name] = tensor
        }

        for spec in Self.outputSpecs {
            guard let tensor = outputs[spec.name], tensor.shape == spec.shape,
                  let count = safeProduct(spec.shape), tensor.values.count == count else {
                throw .malformedRawOutputs
            }
            guard tensor.values.allSatisfy(\.isFinite) else {
                throw .nonFiniteRawValue
            }
        }
        return outputs
    }

    private func decode(
        _ candidate: Candidate
    ) throws(YuNetPostprocessorError) -> DecodedCandidate {
        let stride = Float(candidate.stride)
        let centerX = (Float(candidate.column) + candidate.bbox[0]) * stride
        let centerY = (Float(candidate.row) + candidate.bbox[1]) * stride
        let width = Double(try expandedSize(candidate.bbox[2], stride: stride))
        let height = Double(try expandedSize(candidate.bbox[3], stride: stride))
        let x = Double(centerX) - width / 2
        let y = Double(centerY) - height / 2
        guard centerX.isFinite, centerY.isFinite,
              width.isFinite, height.isFinite, x.isFinite, y.isFinite else {
            throw .numericOverflow
        }
        guard width > 0, height > 0, x >= 0, y >= 0,
              x + width <= 640, y + height <= 640 else {
            throw .invalidGeometry
        }

        var landmarkPoints: [SFaceAlignmentLandmarkRole: NormalizedPoint] = [:]
        for index in 0..<5 {
            let offset = index * 2
            let pointX = (Float(candidate.column) + candidate.landmarks[offset]) * stride
            let pointY = (Float(candidate.row) + candidate.landmarks[offset + 1]) * stride
            landmarkPoints[landmarkRole(index)] = try normalizedPoint(
                x: pointX,
                y: pointY
            )
        }
        let points: SFaceAlignmentLandmarks
        do {
            points = try SFaceAlignmentLandmarks(points: landmarkPoints)
        } catch {
            throw .invalidGeometry
        }
        do {
            let face = try DetectedFace(
                boundingBox: NormalizedRect(
                    x: x / 640,
                    y: 1 - (y + height) / 640,
                    width: width / 640,
                    height: height / 640
                ),
                confidence: Double(candidate.score),
                alignmentLandmarks: points
            )
            return DecodedCandidate(
                candidate: candidate,
                face: face,
                x: x,
                y: y,
                width: width,
                height: height
            )
        } catch {
            throw .invalidGeometry
        }
    }

    private func normalizedPoint(
        x: Float,
        y: Float
    ) throws(YuNetPostprocessorError) -> NormalizedPoint {
        guard x.isFinite, y.isFinite, x >= 0, x <= 640, y >= 0, y <= 640 else {
            throw .invalidGeometry
        }
        do {
            return try NormalizedPoint(x: Double(x) / 640, y: 1 - Double(y) / 640)
        } catch {
            throw .invalidGeometry
        }
    }

    private func integerRect(
        from candidate: DecodedCandidate
    ) throws(YuNetPostprocessorError) -> IntegerRect {
        let x = candidate.x
        let y = candidate.y
        let width = candidate.width
        let height = candidate.height
        let values = [x, y, width, height]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < Double(Int.max) }) else {
            throw .numericOverflow
        }
        let rect = IntegerRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
        guard rect.width > 0, rect.height > 0 else { throw .invalidGeometry }
        return rect
    }

    private func expandedSize(
        _ encoded: Float,
        stride: Float
    ) throws(YuNetPostprocessorError) -> Float {
        guard encoded.isFinite else { throw .numericOverflow }
        let expanded = Foundation.exp(Double(encoded))
        guard expanded.isFinite else { throw .numericOverflow }
        let size = Float(expanded) * stride
        guard size.isFinite else { throw .numericOverflow }
        guard size > 0 else { throw .invalidGeometry }
        return size
    }

    private func intersectionOverUnion(_ lhs: IntegerRect, _ rhs: IntegerRect) -> Double {
        guard lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else { return 0 }
        let left = max(lhs.x, rhs.x)
        let top = max(lhs.y, rhs.y)
        let right = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let bottom = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersectionWidth = max(0, right - left)
        let intersectionHeight = max(0, bottom - top)
        let intersection = intersectionWidth * intersectionHeight
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private func landmarkRole(_ index: Int) -> SFaceAlignmentLandmarkRole {
        switch index {
        case 0: return .subjectRightEye
        case 1: return .subjectLeftEye
        case 2: return .noseTip
        case 3: return .subjectRightMouthCorner
        default: return .subjectLeftMouthCorner
        }
    }

    private func safeProduct(_ values: [Int]) -> Int? {
        values.reduce(1) { partial, value in
            guard let partial, value > 0 else { return nil }
            let result = partial.multipliedReportingOverflow(by: value)
            return result.overflow ? nil : result.partialValue
        }
    }
}
