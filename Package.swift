// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OnAir",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OnAir", targets: ["OnAir"]),
    ],
    targets: [
        .target(name: "OnAir"),
        .testTarget(name: "OnAirTests", dependencies: ["OnAir"]),
    ]
)
