// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KubeView",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "KubeView",
            path: "Sources/KubeView"
        )
    ]
)
