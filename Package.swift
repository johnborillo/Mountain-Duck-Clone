// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenMountainDuck",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "OpenMountainDuckCore",
            targets: ["OpenMountainDuckCore"]
        ),
        .executable(
            name: "OpenMountainDuckApp",
            targets: ["OpenMountainDuckApp"]
        ),
        .executable(
            name: "OpenMountainDuckExtension",
            targets: ["OpenMountainDuckExtension"]
        ),
        .executable(
            name: "omd",
            targets: ["OpenMountainDuckCLI"]
        )
    ],
    targets: [
        .target(
            name: "OpenMountainDuckCore",
            path: "Sources/OpenMountainDuckCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "OpenMountainDuckApp",
            dependencies: [
                "OpenMountainDuckCore"
            ],
            path: "Sources/OpenMountainDuckApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "OpenMountainDuckExtension",
            dependencies: [
                "OpenMountainDuckCore"
            ],
            path: "Sources/OpenMountainDuckExtension",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "OpenMountainDuckCLI",
            dependencies: [
                "OpenMountainDuckCore"
            ],
            path: "Sources/OpenMountainDuckCLI",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
