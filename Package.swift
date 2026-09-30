// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mac-mcp", targets: ["MacMCP"]),
    ],
    targets: [
        .executableTarget(
            name: "MacMCP",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
