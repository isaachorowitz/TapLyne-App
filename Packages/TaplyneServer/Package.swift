// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaplyneServer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TaplyneServer", targets: ["TaplyneServer"])
    ],
    targets: [
        .target(name: "TaplyneServer"),
        .testTarget(name: "TaplyneServerTests", dependencies: ["TaplyneServer"])
    ]
)
