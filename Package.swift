// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "NeoSimulator",
    platforms: [
        .macOS("26.4"),
    ],
    products: [
        .library(
            name: "XcodeSimulatorHost",
            targets: ["XcodeSimulatorHost"]
        ),
    ],
    targets: [
        .target(name: "XcodeSimulatorHost"),
        .testTarget(
            name: "XcodeSimulatorHostTests",
            dependencies: ["XcodeSimulatorHost"]
        ),
    ]
)
