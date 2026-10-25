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
    dependencies: [
        .package(url: "https://github.com/lynnswap/ABIBridge.git", exact: "0.13.0"),
    ],
    targets: [
        .target(name: "XcodeSimulatorHost", dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]),
        .testTarget(
            name: "XcodeSimulatorHostTests",
            dependencies: ["XcodeSimulatorHost"]
        ),
    ]
)
