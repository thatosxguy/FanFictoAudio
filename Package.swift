// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EPUBToMP3",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EPUBToMP3", targets: ["EPUBToMP3"]),
        .executable(name: "epub-audio", targets: ["EPUBAudioCLI"])
    ],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "AudiobookCore", dependencies: ["CZlib"]),
        .executableTarget(name: "EPUBToMP3", dependencies: ["AudiobookCore"]),
        .executableTarget(name: "EPUBAudioCLI", dependencies: ["AudiobookCore"]),
        .testTarget(name: "AudiobookCoreTests", dependencies: ["AudiobookCore"])
    ]
)
