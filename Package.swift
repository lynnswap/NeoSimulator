// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "NeoSimulatorKit",
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
        .package(url: "https://github.com/lynnswap/ABIBridge.git", revision: "68bc1ed1b1278e953429dfb3dc7eaf00ccd6992d"),
    ],
    targets: [
        .target(name: "XcodeSimulatorHost", dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]),
        .testTarget(
            name: "XcodeSimulatorHostTests",
            dependencies: ["XcodeSimulatorHost"]
        ),
    ]
)
