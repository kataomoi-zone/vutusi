// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "offscreen",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/tattn/VRMKit.git", revision: "1afe8811370d05d50367a226bc069c3ab62fd8f2"),
    ],
    targets: [
        .executableTarget(
            name: "offscreen",
            dependencies: [.product(name: "VRMRealityKit", package: "VRMKit")]
        ),
    ]
)
