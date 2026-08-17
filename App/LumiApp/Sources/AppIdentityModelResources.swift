import Foundation

/// The two fixed Core ML resources shipped by the App target.
enum AppIdentityModelResource: String, CaseIterable, Equatable, Sendable {
    case sFace = "SFace"
    case yuNet = "YuNet"

    static let compiledModelExtension = "mlmodelc"

    var noticeName: String {
        switch self {
        case .sFace:
            "SFace-Apache-2.0"
        case .yuNet:
            "YuNet-MIT"
        }
    }
}

/// Stable, payload-free failure for App identity-model resource resolution.
enum AppIdentityModelResourcesError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case failed

    var description: String {
        "App identity model resources failed."
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}

/// Foundation-only resolver boundary for App composition.
///
/// Core ML loading remains in the later Infrastructure composition slice. The
/// App resolves only URLs for already-bundled resources and never downloads,
/// compiles, or globally caches a model here.
protocol AppIdentityModelResourceURLResolving {
    func url(forResource name: String?, withExtension ext: String?) -> URL?
}

extension Bundle: AppIdentityModelResourceURLResolving {}

/// URLs for the compiled models and their redistributable notices.
struct AppIdentityModelResources: Equatable, Sendable {
    static let compiledModelExtension = AppIdentityModelResource.compiledModelExtension
    static let provenanceResourceName = "ModelProvenance"

    let sFaceModelURL: URL
    let yuNetModelURL: URL
    let sFaceNoticeURL: URL
    let yuNetNoticeURL: URL
    let provenanceURL: URL

    /// Resolves every required resource or fails closed without exposing paths.
    static func resolve(
        using resolver: any AppIdentityModelResourceURLResolving
    ) throws -> Self {
        Self(
            sFaceModelURL: try requiredURL(
                name: AppIdentityModelResource.sFace.rawValue,
                ext: compiledModelExtension,
                using: resolver
            ),
            yuNetModelURL: try requiredURL(
                name: AppIdentityModelResource.yuNet.rawValue,
                ext: compiledModelExtension,
                using: resolver
            ),
            sFaceNoticeURL: try requiredURL(
                name: AppIdentityModelResource.sFace.noticeName,
                ext: "txt",
                using: resolver
            ),
            yuNetNoticeURL: try requiredURL(
                name: AppIdentityModelResource.yuNet.noticeName,
                ext: "txt",
                using: resolver
            ),
            provenanceURL: try requiredURL(
                name: provenanceResourceName,
                ext: "json",
                using: resolver
            )
        )
    }

    private static func requiredURL(
        name: String,
        ext: String,
        using resolver: any AppIdentityModelResourceURLResolving
    ) throws -> URL {
        guard let url = resolver.url(forResource: name, withExtension: ext),
              url.isFileURL,
              url.lastPathComponent == "\(name).\(ext)",
              FileManager.default.fileExists(atPath: url.path) else {
            throw AppIdentityModelResourcesError.failed
        }
        return url
    }
}
