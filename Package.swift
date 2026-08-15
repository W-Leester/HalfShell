// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HalfShell",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "HalfShell",
            path: "Sources/HalfShell",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
