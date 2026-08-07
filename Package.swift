// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoClamshell",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AutoClamshell",
            path: "Sources/AutoClamshell",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
