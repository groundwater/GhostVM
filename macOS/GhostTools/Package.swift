// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "GhostTools",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "GhostTools", targets: ["GhostTools"])
    ],
    dependencies: [
        .package(path: "../../Packages/GhostHTTP")
    ],
    targets: [
        .target(
            name: "CPty",
            path: "Sources/CPty",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "GhostTools",
            dependencies: [
                "CPty",
                .product(name: "GhostHTTP", package: "GhostHTTP"),
            ],
            exclude: ["Resources/Info.plist", "Resources/Info.template.plist", "Resources/entitlements.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "../../build/generated-plists/GhostTools-Info.plist"], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "GhostToolsTests",
            dependencies: [
                "GhostTools",
            ]
        )
    ]
)
