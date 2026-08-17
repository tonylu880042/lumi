import CryptoKit
import Foundation
import Testing
@testable import LumiApp

@Suite("App identity model resources")
struct AppIdentityModelResourcesTests {
    @Test("resource descriptors use the fixed compiled model and notice names")
    func resourceDescriptorsAreFixed() {
        #expect(AppIdentityModelResources.compiledModelExtension == "mlmodelc")
        #expect(AppIdentityModelResources.provenanceResourceName == "ModelProvenance")
        #expect(AppIdentityModelResource.sFace.rawValue == "SFace")
        #expect(AppIdentityModelResource.yuNet.rawValue == "YuNet")
        #expect(AppIdentityModelResource.sFace.noticeName == "SFace-Apache-2.0")
        #expect(AppIdentityModelResource.yuNet.noticeName == "YuNet-MIT")
    }

    @Test("missing model or notice resources fail closed")
    func missingResourcesFailClosed() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let files = try makeResourceFiles(in: temporaryDirectory)

        for omitted in ResourceKey.allCases {
            var urls = files
            urls.removeValue(forKey: omitted)
            let resolver = StubResourceResolver(urls: urls)

            #expect(throws: AppIdentityModelResourcesError.failed) {
                try AppIdentityModelResources.resolve(using: resolver)
            }
        }
    }

    @Test("malformed resource URLs fail closed without exposing paths")
    func malformedURLsFailClosed() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let files = try makeResourceFiles(in: temporaryDirectory)
        var malformed = files
        malformed[.sFaceModel] = temporaryDirectory
            .appendingPathComponent("SFace.mlpackage")
        let resolver = StubResourceResolver(urls: malformed)

        do {
            _ = try AppIdentityModelResources.resolve(using: resolver)
            Issue.record("expected malformed resource URL to fail")
        } catch let error as AppIdentityModelResourcesError {
            #expect(error == .failed)
            #expect(String(describing: error) == "App identity model resources failed.")
            #expect(!String(reflecting: error).contains("mlpackage"))
            #expect(!String(reflecting: error).contains(temporaryDirectory.path))
        }
    }

    @Test("host app bundle contains compiled models, notices, and provenance")
    func hostBundleContainsCompiledResources() throws {
        let resources = try AppIdentityModelResources.resolve(using: Bundle.main)

        #expect(resources.sFaceModelURL.lastPathComponent == "SFace.mlmodelc")
        #expect(resources.yuNetModelURL.lastPathComponent == "YuNet.mlmodelc")
        #expect(resources.sFaceNoticeURL.lastPathComponent == "SFace-Apache-2.0.txt")
        #expect(resources.yuNetNoticeURL.lastPathComponent == "YuNet-MIT.txt")
        #expect(resources.provenanceURL.lastPathComponent == "ModelProvenance.json")
        #expect(FileManager.default.fileExists(atPath: resources.sFaceModelURL.path))
        #expect(FileManager.default.fileExists(atPath: resources.yuNetModelURL.path))
        #expect(FileManager.default.fileExists(atPath: resources.sFaceNoticeURL.path))
        #expect(FileManager.default.fileExists(atPath: resources.yuNetNoticeURL.path))
        #expect(FileManager.default.fileExists(atPath: resources.provenanceURL.path))
    }

    @Test("provenance locks source models and copied package component hashes")
    func provenanceLocksModelHashes() throws {
        let url = try #require(
            Bundle.main.url(forResource: "ModelProvenance", withExtension: "json")
        )
        let manifest = try JSONDecoder().decode(
            ProvenanceManifest.self,
            from: Data(contentsOf: url)
        )

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.models["SFace"]?.package == "SFace.mlpackage")
        #expect(manifest.models["YuNet"]?.package == "YuNet.mlpackage")
        #expect(manifest.models["SFace"]?.source.bytes == 38_696_353)
        #expect(manifest.models["YuNet"]?.source.bytes == 232_589)
        #expect(
            manifest.models["SFace"]?.source.sha256
                == "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
        )
        #expect(
            manifest.models["YuNet"]?.source.sha256
                == "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
        )
        #expect(
            manifest.models["SFace"]?.components["Manifest.json"]?.sha256
                == "e5a3ad45ccaae3650d347aee7382043230e6bb202ae0ad07526c34233eb60bc9"
        )
        #expect(
            manifest.models["SFace"]?.components["Data/com.apple.CoreML/model.mlmodel"]?.sha256
                == "9bb092e4b97dd08211e092628f8150f27cd5baa816d2feb57d6c1629272d69ce"
        )
    }

    @Test("tracked package components match the provenance hashes")
    func trackedPackageComponentsMatchHashes() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expected: [(String, String, Int)] = [
            (
                "SFace.mlpackage/Manifest.json",
                "e5a3ad45ccaae3650d347aee7382043230e6bb202ae0ad07526c34233eb60bc9",
                617
            ),
            (
                "SFace.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                "9bb092e4b97dd08211e092628f8150f27cd5baa816d2feb57d6c1629272d69ce",
                44_793
            ),
            (
                "SFace.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                "0d0f19ba62e35fcdc5fe4a6156971ec15b481373150b88295e641a4dd027d37c",
                38_542_848
            ),
            (
                "YuNet.mlpackage/Manifest.json",
                "303cdc31fb58e71a4194d08a37a3cfd94c5568561b3effa657a1a265eb430872",
                617
            ),
            (
                "YuNet.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                "4c1052cf336a9ac3416e9446616ed60c57c859d42d0f8066a0fefae854f7c39b",
                79_398
            ),
            (
                "YuNet.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                "46ee672191a14e03b9794cffb3a381446cf3e886e94ff64dfc9553445924938b",
                217_704
            )
        ]

        for (relativePath, expectedHash, expectedBytes) in expected {
            let url = repositoryRoot
                .appendingPathComponent("App/LumiApp/Resources/Models")
                .appendingPathComponent(relativePath)
            let data = try Data(contentsOf: url)
            #expect(data.count == expectedBytes)
            #expect(hexDigest(data) == expectedHash)
        }
    }

    fileprivate enum ResourceKey: String, CaseIterable {
        case sFaceModel
        case yuNetModel
        case sFaceNotice
        case yuNetNotice
        case provenance
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-model-resource-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func makeResourceFiles(in directory: URL) throws -> [ResourceKey: URL] {
        let names: [ResourceKey: String] = [
            .sFaceModel: "SFace.mlmodelc",
            .yuNetModel: "YuNet.mlmodelc",
            .sFaceNotice: "SFace-Apache-2.0.txt",
            .yuNetNotice: "YuNet-MIT.txt",
            .provenance: "ModelProvenance.json"
        ]
        var urls: [ResourceKey: URL] = [:]
        for (key, name) in names {
            let url = directory.appendingPathComponent(name)
            try Data([0]).write(to: url)
            urls[key] = url
        }
        return urls
    }
}

fileprivate struct StubResourceResolver: AppIdentityModelResourceURLResolving {
    let urls: [AppIdentityModelResourcesTests.ResourceKey: URL]

    func url(forResource name: String?, withExtension ext: String?) -> URL? {
        let key: AppIdentityModelResourcesTests.ResourceKey?
        switch "\(name ?? "").\(ext ?? "")" {
        case "SFace.mlmodelc": key = .sFaceModel
        case "YuNet.mlmodelc": key = .yuNetModel
        case "SFace-Apache-2.0.txt": key = .sFaceNotice
        case "YuNet-MIT.txt": key = .yuNetNotice
        case "ModelProvenance.json": key = .provenance
        default: key = nil
        }
        guard let key else { return nil }
        return urls[key]
    }
}

private struct ProvenanceManifest: Decodable {
    let schemaVersion: Int
    let models: [String: Model]

    struct Model: Decodable {
        let package: String
        let source: Source
        let components: [String: Component]
    }

    struct Source: Decodable {
        let bytes: Int
        let sha256: String
    }

    struct Component: Decodable {
        let bytes: Int
        let sha256: String
    }
}

private func hexDigest(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}
