// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GhostHTTP",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "GhostHTTP",
            targets: ["GhostHTTP"]
        )
    ],
    targets: [
        .target(
            name: "GhostHTTP"
        ),
        .testTarget(
            name: "GhostHTTPTests",
            dependencies: ["GhostHTTP"]
        )
    ]
)
