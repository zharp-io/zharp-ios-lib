// swift-tools-version:5.9
//
// Zharp for iOS. The `Zharp` library is what apps add; `ZharpCore` is its plain-Swift logic
// (attribute mapping, sessions, propagation headers, sampling, retry, crash report formatting)
// with no dependencies, kept apart so it can be tested on its own. `ZharpCxx` is a few lines of
// C++ for apps with C++ in them: an uncaught C++ exception's type and message in its crash report.
//
// OpenTelemetry Swift 2.x requires Swift 6 tools to build, so Xcode 16 or later.

import PackageDescription

let package = Package(
    name: "Zharp",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "Zharp", targets: ["Zharp"]),
        // Optional: swift-log's Logger into Zharp (`ZharpLogHandler`).
        .library(name: "ZharpLogging", targets: ["ZharpLogging"]),
    ],
    dependencies: [
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", exact: "2.6.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", exact: "2.6.0"),
        // Already in the graph through OpenTelemetry Swift; named here for ZharpLogging.
        // Below 1.17: from 1.17 swift-log needs a newer compiler than Xcode 26.0–26.2 have, while
        // declaring tools 6.2, so those Xcodes pick it and then can't build it.
        .package(url: "https://github.com/apple/swift-log.git", "1.5.0"..<"1.17.0"),
    ],
    targets: [
        .target(
            name: "ZharpCore",
            path: "Sources/ZharpCore"
        ),
        // Uncaught C++ exceptions' type and what() for crash reports (a std::terminate handler).
        .target(
            name: "ZharpCxx",
            path: "Sources/ZharpCxx"
        ),
        .target(
            name: "Zharp",
            dependencies: [
                "ZharpCore",
                "ZharpCxx",
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
                .product(name: "URLSessionInstrumentation", package: "opentelemetry-swift"),
            ],
            path: "Sources/Zharp"
        ),
        .target(
            name: "ZharpLogging",
            dependencies: [
                "Zharp",
                "ZharpCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ZharpLogging"
        ),
        .testTarget(
            name: "ZharpCoreTests",
            dependencies: ["ZharpCore"],
            path: "Tests/ZharpCoreTests"
        ),
        .testTarget(
            name: "ZharpTests",
            dependencies: [
                "Zharp",
                "ZharpCore",
                "ZharpLogging",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
            ],
            path: "Tests/ZharpTests"
        ),
    ]
)
