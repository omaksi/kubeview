// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KubeView",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KubeView", targets: ["KubeView"]),
        .executable(name: "LgtmView", targets: ["LgtmView"])
    ],
    targets: [
        // Layer 1 - pure. Foundation only. No I/O, no SwiftUI.
        .target(name: "KubeModel"),

        // Layer 2 - all cluster I/O. Foundation only, so a headless tool can link it.
        .target(name: "KubeClient", dependencies: ["KubeModel"]),

        // Layer 3 - shared SwiftUI chrome. Only GUI apps link this.
        .target(name: "KubeUI", dependencies: ["KubeModel", "KubeClient"]),

        // The cluster browser. Logic lives in the kit so tests can import it;
        // the executable is a ~6 line @main shell.
        .target(name: "KubeViewKit", dependencies: ["KubeModel", "KubeClient", "KubeUI"]),
        .executableTarget(name: "KubeView", dependencies: ["KubeViewKit"]),

        // The LGTM stack inspector. Same shape as KubeView: logic in the kit
        // so tests can import it, a ~6 line @main shell for the executable.
        .target(name: "LgtmViewKit", dependencies: ["KubeModel", "KubeClient", "KubeUI"]),
        .executableTarget(name: "LgtmView", dependencies: ["LgtmViewKit"])
    ]
)
