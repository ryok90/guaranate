// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Guaranate",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "guaranate", targets: ["GuaranateCLI"]),
        .library(name: "GuaranateCore", targets: ["GuaranateCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "GuaranateCore"
        ),
        .executableTarget(
            name: "GuaranateCLI",
            dependencies: [
                "GuaranateCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "GuaranateCoreTests",
            dependencies: ["GuaranateCore"]
        ),
    ]
)
