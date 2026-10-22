// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Public is the default, even when ignored personal sources exist on this machine.
let localFeatures = ProcessInfo.processInfo.environment["YUKINO_LOCAL_FEATURES"] == "1"
    && ProcessInfo.processInfo.environment["YUKINO_PUBLIC_RELEASE"] != "1"
let featureSettings: [SwiftSetting] = localFeatures ? [.define("YUKINO_LOCAL_FEATURES")] : []
func featureExclusions(_ target: String) -> [String] {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent(target).appendingPathComponent("LocalFeatures")
    return !localFeatures && FileManager.default.fileExists(atPath: directory.path) ? ["LocalFeatures"] : []
}

let package = Package(
    name: "YukinoTools",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "YukinoCore", targets: ["YukinoCore"]),
        .executable(name: "YukinoTools", targets: ["YukinoTools"])
    ],
    targets: [
        .target(name: "YukinoCore", exclude: featureExclusions("Sources/YukinoCore"), swiftSettings: featureSettings),
        .executableTarget(name: "YukinoTools", dependencies: ["YukinoCore"], exclude: featureExclusions("Sources/YukinoTools"), swiftSettings: featureSettings),
        .testTarget(name: "YukinoCoreTests", dependencies: ["YukinoCore"], exclude: featureExclusions("Tests/YukinoCoreTests"), swiftSettings: featureSettings)
    ],
    swiftLanguageModes: [.v5]
)
