// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "vvx",
    platforms: [
        .macOS(.v14)   // Apple platform minimum; Linux builds ignore this.
    ],
    products: [
        // Core engine library — imported by the macOS app as its Swift Package dependency.
        .library(
            name: "VideoVortexCore",
            targets: ["VideoVortexCore"]
        ),
        // Primary CLI product: brew install videovortex-app/tap/vvx
        .executable(
            name: "vvx",
            targets: ["vvx"]
        ),
        // MCP server: lets Claude Desktop, Cursor, and Windsurf call vvx as a native tool.
        .executable(
            name: "vvx-mcp",
            targets: ["VvxMcp"]
        ),
        // Local HTTP agent API: vvx serve --port 4242
        .executable(
            name: "vvx-serve",
            targets: ["VvxServe"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.7.1"
        ),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            from: "2.21.1"
        ),
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.0.0"
        ),
    ],
    targets: [

        // MARK: - Core Library

        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"]),
            ]
        ),

        .target(
            name: "VideoVortexCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "CSQLite",
            ],
            path: "Sources/VideoVortexCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),

        // MARK: - vvx CLI

        .executableTarget(
            name: "vvx",
            dependencies: [
                "VideoVortexCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/vvx"
        ),

        // MARK: - vvx-mcp (MCP Server — Phase 2)

        .executableTarget(
            name: "VvxMcp",
            dependencies: [
                "VideoVortexCore",
            ],
            path: "Sources/VvxMcp"
        ),

        // MARK: - vvx-serve (Local HTTP API — Phase 4)

        .executableTarget(
            name: "VvxServe",
            dependencies: [
                "VideoVortexCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/VvxServe"
        ),

        // MARK: - Tests

        .testTarget(
            name: "VideoVortexCoreTests",
            dependencies: ["VideoVortexCore"],
            path: "Tests/VideoVortexCoreTests"
        ),
    ]
)
