// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HalfShell",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0")
    ],
    targets: [
        .executableTarget(
            name: "HalfShell",
            dependencies: [.product(name: "Sentry", package: "sentry-cocoa")],
            path: "Sources/HalfShell",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
