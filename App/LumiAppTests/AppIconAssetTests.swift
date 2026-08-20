import Foundation
import ImageIO
import Testing

@Suite("App icon asset contract")
struct AppIconAssetTests {
    @Test("The root asset catalog and AppIcon set are valid")
    func appIconCatalogHasOneIOSUniversalEntry() throws {
        let catalogURL = projectRoot
            .appendingPathComponent("App/LumiApp/Resources/Assets.xcassets")
        let catalogContents = try jsonObject(
            at: catalogURL.appendingPathComponent("Contents.json")
        )
        #expect(catalogContents["info"] is [String: Any])

        let appIconContents = try jsonObject(
            at: catalogURL
                .appendingPathComponent("AppIcon.appiconset")
                .appendingPathComponent("Contents.json")
        )
        let images = try #require(appIconContents["images"] as? [[String: Any]])
        #expect(images.count == 1)

        let image = try #require(images.first)
        #expect(image["filename"] as? String == "LumiAppIcon-1024.png")
        #expect(image["idiom"] as? String == "universal")
        #expect(image["platform"] as? String == "ios")
        #expect(image["size"] as? String == "1024x1024")
    }

    @Test("The source icon is an exact opaque RGB 1024 PNG")
    func sourceIconHasExpectedPixelsAndColorModel() throws {
        let iconURL = projectRoot
            .appendingPathComponent("App/LumiApp/Resources/Assets.xcassets")
            .appendingPathComponent("AppIcon.appiconset")
            .appendingPathComponent("LumiAppIcon-1024.png")

        guard let source = CGImageSourceCreateWithURL(iconURL as CFURL, nil) else {
            Issue.record("App icon PNG could not be opened by ImageIO")
            return
        }

        #expect(CGImageSourceGetCount(source) == 1)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("App icon PNG did not decode into a CGImage")
            return
        }
        #expect(image.width == 1024)
        #expect(image.height == 1024)

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
        #expect(properties?[kCGImagePropertyColorModel] as? String == "RGB")
        // ImageIO omits HasAlpha for an opaque PNG; only a true value means alpha is present.
        #expect(properties?[kCGImagePropertyHasAlpha] as? Bool != true)
    }

    @Test("The App target wires the asset catalog and icon name in all configurations")
    func projectWiresAssetCatalogAndAppIconName() throws {
        let projectURL = projectRoot
            .appendingPathComponent("App/LumiApp.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        #expect(project.contains("Assets.xcassets"))
        #expect(project.contains("lastKnownFileType = folder.assetcatalog"))
        #expect(project.contains("Assets.xcassets in Resources"))
        #expect(
            project.components(separatedBy: "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;").count - 1
                == 4
        )
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }
}
