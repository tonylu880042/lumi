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
    targets: [
        .target(name: "LumiDomain"),
        .target(name: "LumiApplication", dependencies: ["LumiDomain"]),
        .target(name: "LumiPresentation", dependencies: ["LumiDomain"]),
        .target(name: "LumiInfrastructure", dependencies: ["LumiApplication", "LumiDomain"]),
        .target(name: "LumiUI", dependencies: ["LumiPresentation"]),
        .testTarget(name: "LumiPresentationTests", dependencies: ["LumiPresentation"]),
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
