// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PixView",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "PixView", path: "Sources/PixView")
    ]
)
