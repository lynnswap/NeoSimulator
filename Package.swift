// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "NeoSimulatorKit",
    platforms: [.macOS("26.4")],
    products: [
        .library(name: "NeoSimulatorKit", targets: ["NeoSimulatorKit"]),
        .library(name: "XcodeSimulatorHost", targets: ["XcodeSimulatorHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/lynnswap/ABIBridge.git", exact: "0.16.2"),
        .package(url: "https://github.com/lynnswap/ObservationBridge.git", exact: "0.15.7"),
    ],
    targets: [
        .target(name: "XcodeSimulatorHost", dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]),
        .target(
            name: "NeoSimulatorKit",
            dependencies: [
                "XcodeSimulatorHost",
                .product(name: "ABIBridge", package: "ABIBridge"),
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ],
            path: "Modules/Sources/NeoSimulatorKit"
        ),
        .testTarget(name: "XcodeSimulatorHostTests", dependencies: ["XcodeSimulatorHost"]),
    ]
)
