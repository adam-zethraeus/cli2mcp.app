// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Cli2MCP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Cli2MCPCore", targets: ["Cli2MCPCore"]),
        .executable(name: "cli2mcp-server", targets: ["Cli2MCPServer"]),
        .executable(name: "Cli2MCPApp", targets: ["Cli2MCPApp"])
    ],
    targets: [
        .target(
            name: "Cli2MCPCore",
            path: "Sources/Cli2MCPCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Cli2MCPServer",
            dependencies: ["Cli2MCPCore"],
            path: "Sources/Cli2MCPServer",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Cli2MCPApp",
            dependencies: ["Cli2MCPCore"],
            path: "Sources/Cli2MCPApp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "Cli2MCPCoreTests",
            dependencies: ["Cli2MCPCore"],
            path: "Tests/Cli2MCPCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "Cli2MCPServerIntegrationTests",
            dependencies: ["Cli2MCPCore"],
            path: "Tests/Cli2MCPServerIntegrationTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "Cli2MCPAppTests",
            dependencies: ["Cli2MCPApp"],
            path: "Tests/Cli2MCPAppTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
