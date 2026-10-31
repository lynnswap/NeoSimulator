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
        .package(url: "https://github.com/lynnswap/ABIBridge.git", revision: "d78cf5f170941635ff94e8617ca8743eebe40898"),
    ],
    targets: [
        .target(name: "XcodeSimulatorHost", dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]),
        .testTarget(
            name: "XcodeSimulatorHostTests",
            dependencies: ["XcodeSimulatorHost"]
        ),
    ]
)
