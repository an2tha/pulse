// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PulseEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PulseEngine", targets: ["PulseEngine"])],
    targets: [.target(name: "PulseEngine"), .testTarget(name: "PulseEngineTests", dependencies: ["PulseEngine"])]
)
