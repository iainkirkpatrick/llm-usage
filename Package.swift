// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMUsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LLMUsageCore", targets: ["LLMUsageCore"]),
        .executable(name: "llm-usage", targets: ["LLMUsageCLI"]),
        .executable(name: "LLMUsageBar", targets: ["LLMUsageBar"]),
    ],
    targets: [
        .target(name: "LLMUsageCore", resources: [.process("Resources")]),
        .executableTarget(name: "LLMUsageCLI", dependencies: ["LLMUsageCore"]),
        .executableTarget(
            name: "LLMUsageBar", dependencies: ["LLMUsageCore"],
            path: "Sources/LLMUsageBar", resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Security")]
        ),
        .testTarget(name: "LLMUsageCoreTests", dependencies: ["LLMUsageCore"]),
    ]
)
