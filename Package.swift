// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevSweep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DevSweepCore", targets: ["DevSweepCore"]),
        .executable(name: "devsweep", targets: ["devsweep"]),
        .executable(name: "DevSweepApp", targets: ["DevSweepApp"]),
    ],
    targets: [
        .target(name: "DevSweepCore"),
        .executableTarget(name: "devsweep", dependencies: ["DevSweepCore"]),
        .executableTarget(name: "DevSweepApp", dependencies: ["DevSweepCore"]),
        .testTarget(name: "DevSweepCoreTests", dependencies: ["DevSweepCore"]),
    ],
    swiftLanguageModes: [.v5]
)
