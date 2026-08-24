// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenDuck",
    platforms: [
        .macOS(.v13)
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
    targets: [
        .target(
            name: "OpenDuckCore",
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
        .testTarget(
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

