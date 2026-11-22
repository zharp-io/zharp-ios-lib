// swift-tools-version:5.9
//
// A bare AppKit app for checking Zharp on macOS end to end (.github/workflows/macos-e2e.yml):
// it crashes, reports a handled error and quits, or relaunches to send the last crash.

import PackageDescription

let package = Package(
    name: "MacE2E",
    platforms: [.macOS(.v12)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "MacE2E",
            dependencies: [.product(name: "Zharp", package: "zharp-ios-sdk")],
            path: "Sources/MacE2E"
        ),
    ]
)
