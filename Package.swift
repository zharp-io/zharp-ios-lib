// swift-tools-version:5.9
//
// Zharp for iOS. The `Zharp` library is what apps add; `ZharpCore` is its plain-Swift logic
// (attribute mapping, sessions, propagation headers, sampling, retry, crash report formatting)
// with no dependencies, kept apart so it can be tested on its own.
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
    ],
    dependencies: [
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", exact: "2.6.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", exact: "2.6.0"),
    ],
    targets: [
        .target(
            name: "ZharpCore",
            path: "Sources/ZharpCore"
        ),
        .target(
            name: "Zharp",
            dependencies: [
                "ZharpCore",
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
                .product(name: "URLSessionInstrumentation", package: "opentelemetry-swift"),
            ],
            path: "Sources/Zharp"
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
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
            ],
            path: "Tests/ZharpTests"
        ),
    ]
)
