// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenshotTool",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenshotTool",
            path: "Sources/ScreenshotTool"
        )
    ]
)
