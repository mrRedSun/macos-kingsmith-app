// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WalkingPad",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "WalkingPad", targets: ["WalkingPadApp"])],
    targets: [
        .target(name: "WalkingPadCore"),
        .executableTarget(name: "WalkingPadApp", dependencies: ["WalkingPadCore"]),
        .testTarget(name: "WalkingPadCoreTests", dependencies: ["WalkingPadCore"]),
        .testTarget(name: "WalkingPadUITests", dependencies: ["WalkingPadApp"])
    ]
)
