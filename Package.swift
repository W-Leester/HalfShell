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
        ),
        // 판단 로직(유령 판별·관문·복구 재시도 양보)의 시험.
        // 실제 동작을 좌우하는 코드라 실측 사례를 그대로 입력으로 넣어 둔다.
        // 실행: swift test
        .testTarget(
            name: "HalfShellTests",
            dependencies: ["HalfShell"],
            path: "Tests/HalfShellTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
