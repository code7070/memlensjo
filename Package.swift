// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemLens",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MemLens", path: "Sources/MemLens")
    ]
)
