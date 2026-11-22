// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacCommander",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MacCommander", path: "Sources/MacCommander"),
        .testTarget(name: "MacCommanderTests", dependencies: ["MacCommander"], path: "Tests/MacCommanderTests")
    ]
)
