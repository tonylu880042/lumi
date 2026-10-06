@preconcurrency import CoreML
import Foundation
import LumiDomain
@testable import LumiInfrastructure
import Testing

/// Opt-in, real implementation microbenchmark. Synthetic pixels/vectors are
/// deliberately not presented as camera, face accuracy, or iPhone latency.
@Suite("Identity performance profile", .serialized)
struct IdentityPerformanceProfileTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUMI_PROFILE_OUTPUT"] != nil))
    func profileIdentityComponents() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["LUMI_PROFILE_OUTPUT"])
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-profile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var stages: [String: [Double]] = [:]
        let clock = ContinuousClock()

        func measure<T>(_ name: String, _ operation: () async throws -> T) async throws -> T {
            let start = clock.now
            let value = try await operation()
            let elapsed = start.duration(to: clock.now).components
            stages[name, default: []].append(
                Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            )
            return value
        }

        func load(_ name: String) async throws -> sending MLModel {
            let package = root.appendingPathComponent("App/LumiApp/Resources/Models/\(name).mlpackage")
            let compiled = try await measure("\(name).compile.host-only") {
                try MLModel.compileModel(at: package)
            }
            defer { try? FileManager.default.removeItem(at: compiled) }
            let start = clock.now
            let model = try await MLModel.load(contentsOf: compiled, configuration: MLModelConfiguration())
            let elapsed = start.duration(to: clock.now).components
            stages["\(name).load.once"] = [Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15]
            return model
        }

        let yuNet = try YuNetCoreMLRawInference(model: await load("YuNet"))
        let sFace = try SFaceCoreMLInference(model: await load("SFace"))
        let frame = try CameraFrame(
            bytes: Data(repeating: 127, count: 640 * 480 * 4),
            width: 640, height: 480, bytesPerRow: 640 * 4, orientation: .upright
        )
        let points = [(38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366),
                      (41.5493, 92.3655), (70.7299, 92.2041)]
        let landmarks = try SFaceAlignmentLandmarks(points: Dictionary(uniqueKeysWithValues:
            zip(SFaceAlignmentLandmarkRole.allCases, points).map { role, point in
                (role, try NormalizedPoint(x: point.0 / 640, y: 1 - point.1 / 480))
            }
        ))
        let postprocessor = try YuNetPostprocessor(configuration: .validationDefault)
        // First invocation is reported separately; 30 subsequent calls form warm statistics.
        for iteration in 0...30 {
            let phase = iteration == 0 ? "first" : "warm"
#if os(iOS)
            let faces = try await measure("vision.blank-frame.\(phase)") {
                try await VisionFaceDetector().detect(frame: frame)
            }
            #expect(faces.isEmpty)
#endif
            let input = try await measure("yunet.preprocess.\(phase)") {
                try YuNetVImagePreprocessor().preprocess(frame: frame)
            }
            let tensors = try await measure("yunet.inference-wrapper.\(phase)") {
                try await yuNet.predict(input)
            }
            _ = try await measure("yunet.postprocess.blank-frame.\(phase)") {
                try postprocessor.process(tensors)
            }
            let crop = try await measure("sface.align.synthetic-landmarks.\(phase)") {
                try SFaceAlignmentCropper().crop(frame: frame, landmarks: landmarks)
            }
            let embedding = try await measure("sface.inference-wrapper.\(phase)") {
                try await sFace.embedding(for: crop)
            }
            #expect(embedding.components.count == 128)
        }

        let matcher = BruteForceCosineFaceMatcher()
        let policy = RecognitionConfidencePolicy(configuration: .pilot44B)
        let knownQuery = try vector(seed: 1)
        let unknownQuery = try vector(seed: 9_999_999)
        for memberCount in [10, 100, 800] {
            let store = try SQLiteFaceEmbeddingStore(
                databaseURL: temp.appendingPathComponent("gallery-\(memberCount).sqlite")
            )
            for index in 0..<memberCount {
                let member = try MemberID(rawValue: "synthetic-\(index)")
                for sample in 0..<5 {
                    let embedding = index == 0 ? knownQuery : try vector(seed: UInt64(index * 5 + sample + 2))
                    try await store.save(memberID: member, embedding: embedding, createdAt: Date(timeIntervalSince1970: 0))
                }
            }
            let cachedGallery = try await store.sFaceSamples()
            #expect(cachedGallery.count == memberCount * 5)
            for (label, query) in [("known", knownQuery), ("unknown", unknownQuery)] {
                for _ in 0..<30 {
                    let gallery = try await measure("gallery.\(memberCount).\(label).read-decode") {
                        try await store.sFaceSamples()
                    }
                    let evidence = try await measure("gallery.\(memberCount).\(label).match") {
                        try matcher.evidence(for: query, against: gallery)
                    }
                    let best = try #require(evidence.bestCandidate)
                    let observation = RecognitionObservation.ranked(
                        best: try RecognitionMatchCandidate(memberID: best.memberID, similarity: best.cosineSimilarity),
                        second: try evidence.secondCandidate.map {
                            try RecognitionMatchCandidate(memberID: $0.memberID, similarity: $0.cosineSimilarity)
                        }
                    )
                    let decision = policy.decide(observations: Array(repeating: observation, count: 3))
                    switch decision {
                    case .known: #expect(label == "known")
                    case .unknown: #expect(label == "unknown")
                    }
                }
            }
        }
#if DEBUG
        let configuration = "debug"
#else
        let configuration = "release"
#endif
        let report: [String: Any] = [
            "scope": "macOS synthetic component profile; not physical-camera or voice end-to-end latency",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processor_count": ProcessInfo.processInfo.processorCount,
            "configuration": ProcessInfo.processInfo.environment["LUMI_PROFILE_CONFIGURATION"] ?? configuration,
            "compute_units": "MLModelConfiguration default (same as production factory)",
            "input": "640x480 uniform BGRA; fixed synthetic alignment; seeded 128D vectors; 5 samples/member",
            "excluded": "camera/frame wait, native Vision on macOS (production adapter is iOS-only), real faces, presence, network, voice; no end-to-end total",
            "stages_ms": stages.mapValues { samples -> [String: Any] in
                let sorted = samples.sorted()
                return ["n": samples.count, "first": samples[0],
                        "p50": sorted[Int(ceil(Double(sorted.count) * 0.50)) - 1],
                        "p95": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
                        "min": sorted[0], "max": sorted[sorted.count - 1], "samples": samples]
            }
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    private func vector(seed: UInt64) throws -> FaceEmbedding {
        var state = seed
        let values: [Float] = (0..<128).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24) * 2 - 1
        }
        return try FaceEmbedding(modelVersion: SFaceCoreMLInference.modelVersion, components: values)
    }
}
