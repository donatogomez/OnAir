// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OnAirDemo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "OnAirDemo",
            dependencies: [.product(name: "OnAir", package: "OnAir")]
        ),
    ]
)
