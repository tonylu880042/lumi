// swift-tools-version: 6.0
import PackageDescription

// LumiDomain 不依賴 LumiPresentation —— 狀態邊界由 target 依賴方向強制，
// 不是靠自律。Domain 想拿座標或 SwiftUI 型別會編譯不過。
let package = Package(
    name: "Lumi",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LumiDomain", targets: ["LumiDomain"]),
        .library(name: "LumiApplication", targets: ["LumiApplication"]),
        .library(name: "LumiPresentation", targets: ["LumiPresentation"]),
        .library(name: "LumiInfrastructure", targets: ["LumiInfrastructure"]),
        .library(name: "LumiUI", targets: ["LumiUI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/stasel/WebRTC.git",
            exact: "151.0.0"
        )
    ],
    targets: [
        .target(name: "LumiDomain"),
        .target(name: "LumiApplication", dependencies: ["LumiDomain"]),
        .target(name: "LumiPresentation", dependencies: ["LumiApplication", "LumiDomain"]),
        .target(
            name: "LumiInfrastructure",
            dependencies: [
                "LumiApplication",
                "LumiDomain",
                .product(name: "WebRTC", package: "WebRTC")
            ]
        ),
        .target(name: "LumiUI", dependencies: ["LumiPresentation"]),
        .testTarget(name: "LumiPresentationTests", dependencies: ["LumiPresentation", "LumiApplication"]),
        .testTarget(
            name: "LumiUISnapshotTests",
            dependencies: ["LumiUI", "LumiPresentation", "LumiDomain"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "LumiDomainTests", dependencies: ["LumiDomain"]),
        .testTarget(name: "LumiApplicationTests", dependencies: ["LumiApplication", "LumiDomain"]),
        .testTarget(name: "LumiInfrastructureTests", dependencies: ["LumiInfrastructure", "LumiApplication", "LumiDomain"]),
    ]
)
