// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ToothlessStreaming",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "StreamingCore", targets: ["StreamingCore"])],
    targets: [
        .target(name: "StreamingCore"),
        .testTarget(name: "StreamingCoreTests", dependencies: ["StreamingCore"])
    ]
)