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
    dependencies: [],
    targets: [
        .executableTarget(
            name: "GhostTools",
            dependencies: [],
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/GhostTools/Resources/Info.plist"], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "GhostToolsTests",
            dependencies: ["GhostTools"]
        )
    ]
)
