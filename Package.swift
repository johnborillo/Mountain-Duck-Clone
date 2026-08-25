// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenDuck",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "OpenDuckCore",
            targets: ["OpenDuckCore"]
        ),
        .executable(
            name: "OpenDuckApp",
            targets: ["OpenDuckApp"]
        ),
        .executable(
            name: "OpenDuckExtension",
            targets: ["OpenDuckExtension"]
        ),
        .executable(
            name: "openduck",
            targets: ["OpenDuckCLI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0")
    ],
    targets: [
        .target(
            name: "OpenDuckCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel")
            ],
            path: "Sources/OpenDuckCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "OpenDuckApp",
            dependencies: [
                "OpenDuckCore"
            ],
            path: "Sources/OpenDuckApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "OpenDuckExtension",
            dependencies: [
                "OpenDuckCore"
            ],
            path: "Sources/OpenDuckExtension",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                // App extensions are mainless. Foundation's extension host
                // owns the process entry point and dispatches to the class
                // named by NSExtensionPrincipalClass.
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
            ]
        ),
        .executableTarget(
            name: "OpenDuckCLI",
            dependencies: [
                "OpenDuckCore"
            ],
            path: "Sources/OpenDuckCLI",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "OpenDuckTests",
            dependencies: [
                "OpenDuckCore"
            ],
            path: "Tests/OpenDuckTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
