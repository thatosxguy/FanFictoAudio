// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FanFicToAudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FanFicToAudio", targets: ["FanFicToAudio"]),
        .executable(name: "epub-audio", targets: ["EPUBAudioCLI"])
    ],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "AudiobookCore", dependencies: ["CZlib"]),
        .target(name: "DownloadCore"),
        .executableTarget(name: "FanFicToAudio", dependencies: ["AudiobookCore", "DownloadCore"]),
        .executableTarget(name: "EPUBAudioCLI", dependencies: ["AudiobookCore"]),
        .testTarget(name: "AudiobookCoreTests", dependencies: ["AudiobookCore"]),
        .testTarget(name: "DownloadCoreTests", dependencies: ["DownloadCore"])
    ]
)
