// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YukinoTools",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "YukinoCore", targets: ["YukinoCore"]),
        .executable(name: "YukinoTools", targets: ["YukinoTools"])
    ],
    targets: [
        .target(name: "YukinoCore"),
        .executableTarget(name: "YukinoTools", dependencies: ["YukinoCore"]),
        .testTarget(name: "YukinoCoreTests", dependencies: ["YukinoCore"])
    ],
    swiftLanguageModes: [.v5]
)
