// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PicoLEDControlSwift",
    platforms: [
        .macOS(.v14)  // Runs on macOS, sends commands to Pico via serial
    ],
    products: [
        .library(
            name: "PicoLEDControlLib",
            targets: ["PicoLEDControlLib"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        .package(url: "https://github.com/Mikedan37/BlazeBinary.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "PicoLEDControlLib",
            dependencies: [
                .product(name: "BlazeBinary", package: "BlazeBinary"),
            ]
        ),
        .executableTarget(
            name: "PicoLEDControl",
            dependencies: [
                "PicoLEDControlLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "BlazeMetrics",
            dependencies: [
                "PicoLEDControlLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "PipelineVerifier",
            dependencies: [
                "PicoLEDControlLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "PicoLEDControlTests",
            dependencies: ["PicoLEDControlLib"]
        ),
        .testTarget(
            name: "TelemetryTests",
            dependencies: ["PicoLEDControlLib"]
        ),
        .testTarget(
            name: "ChaosTests",
            dependencies: ["PicoLEDControlLib"]
        ),
    ]
)
