// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "posecheck",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/tattn/VRMKit.git", revision: "1afe8811370d05d50367a226bc069c3ab62fd8f2"),
    ],
    targets: [
        // TrackingApplier.swift and HolisticResult.swift are symlinks into Sources/App/Tracking.
        .executableTarget(
            name: "posecheck",
            dependencies: [.product(name: "VRMRealityKit", package: "VRMKit")]
        ),
    ]
)
