// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PicoBenchmarks",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../PicoLEDControlSwift")
    ],
    targets: [
        .executableTarget(
            name: "PerformanceBenchmark",
            dependencies: [
                .product(name: "PicoLEDControlLib", package: "PicoLEDControlSwift")
            ]
        )
    ]
)
