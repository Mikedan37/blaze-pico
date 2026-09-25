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
        // BlazeBinary with UInt8 support (feature/blazebinary-c-interop). Local path until that
        // branch is pushed and tagged; switch to the GitHub URL before this package is published.
        .package(path: "../../../Developer/blaze-interop/BlazeBinary"),
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
