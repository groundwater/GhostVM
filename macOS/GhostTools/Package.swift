// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GhostTools",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GhostTools", targets: ["GhostTools"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "GhostTools",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "GhostToolsTests",
            dependencies: ["GhostTools"]
        )
    ]
)
