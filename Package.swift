// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TiltBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TiltBar", path: "Sources/TiltBar")
    ]
)
