// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sugrob",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Sugrob", targets: ["Sugrob"]),
        .library(name: "SnowCore", targets: ["SnowCore"]),
    ],
    targets: [
        // Pure simulation logic. Must not import AppKit/Metal so it stays testable anywhere.
        .target(name: "SnowCore"),
        .executableTarget(
            name: "Sugrob",
            dependencies: ["SnowCore"]
        ),
        .testTarget(
            name: "SnowCoreTests",
            dependencies: ["SnowCore"]
        ),
    ]
)
