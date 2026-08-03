// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MediaTool",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MediaTool",
            path: "Sources/MediaTool"
        )
    ]
)
