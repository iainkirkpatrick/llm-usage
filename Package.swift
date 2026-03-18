// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMUsageBar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "LLMUsageBar", targets: ["LLMUsageBar"]),
    ],
    targets: [
        .executableTarget(
            name: "LLMUsageBar",
            path: "Sources/LLMUsageBar",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
