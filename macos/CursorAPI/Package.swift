// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CursorAPI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CursorAPICore", targets: ["CursorAPICore"]),
        .executable(name: "CursorAPI", targets: ["CursorAPI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .target(
            name: "CursorAPICore",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "CursorAPI",
            dependencies: [
                "CursorAPICore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "CursorAPITests",
            dependencies: ["CursorAPICore", "CursorAPI"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        )
    ]
)
