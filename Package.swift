// swift-tools-version: 6.0
import PackageDescription

// LumiDomain 不依賴 LumiPresentation —— 狀態邊界由 target 依賴方向強制，
// 不是靠自律。Domain 想拿座標或 SwiftUI 型別會編譯不過。
let package = Package(
    name: "Lumi",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LumiDomain", targets: ["LumiDomain"]),
        .library(name: "LumiPresentation", targets: ["LumiPresentation"]),
        .library(name: "LumiUI", targets: ["LumiUI"]),
    ],
    targets: [
        .target(name: "LumiDomain"),
        .target(name: "LumiPresentation", dependencies: ["LumiDomain"]),
        .target(name: "LumiUI", dependencies: ["LumiDomain", "LumiPresentation"]),
        .testTarget(name: "LumiPresentationTests", dependencies: ["LumiPresentation"]),
    ]
)
