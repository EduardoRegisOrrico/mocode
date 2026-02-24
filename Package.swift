// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mocode",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(name: "Mocode", targets: ["Mocode"])
    ],
    targets: [
        .binaryTarget(
            name: "codex_bridge",
            path: "Frameworks/codex_bridge.xcframework"
        ),
        .target(
            name: "Mocode",
            dependencies: ["codex_bridge"],
            path: "Sources/Mocode",
            publicHeadersPath: "Bridge"
        )
    ]
)
