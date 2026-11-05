// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "NeoSimulatorKit",
    defaultLocalization: "en",
    platforms: [.macOS("26.4")],
    products: [
        .library(name: "NeoSimulatorKit", targets: ["NeoSimulatorKit"]),
        .library(name: "NeoSimulatorApp", targets: ["NeoSimulatorApp"]),
        .library(name: "NeoSimulatorService", targets: ["NeoSimulatorService"]),
    ],
    dependencies: [
        .package(url: "https://github.com/lynnswap/ABIBridge.git", exact: "0.16.2"),
        .package(url: "https://github.com/lynnswap/ObservationBridge.git", exact: "0.15.7"),
    ],
    targets: [
        .target(
            name: "NeoSimulatorKit",
            dependencies: [
                .product(name: "ABIBridge", package: "ABIBridge"),
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ],
            path: "Modules/Sources/NeoSimulatorKit"
        ),
        .target(name: "NeoSimulatorHostSupport", dependencies: [
            "NeoSimulatorKit",
            .product(name: "ABIBridge", package: "ABIBridge"),
            .product(name: "ObservationBridge", package: "ObservationBridge"),
        ], path: "Modules/Sources/NeoSimulatorHostSupport"),
        .target(name: "NeoSimulatorApp", dependencies: [
            "NeoSimulatorKit", "NeoSimulatorHostSupport",
            .product(name: "ObservationBridge", package: "ObservationBridge"),
        ], path: "Modules/Sources/NeoSimulatorApp", resources: [.process("Resources")]),
        .target(name: "NeoSimulatorService", dependencies: [
            "NeoSimulatorKit", "NeoSimulatorHostSupport",
        ], path: "Modules/Sources/NeoSimulatorService"),
        .testTarget(name: "NeoSimulatorAppTests", dependencies: [
            "NeoSimulatorApp", "NeoSimulatorKit", "NeoSimulatorHostSupport", "NeoSimulatorService",
            .product(name: "ABIBridge", package: "ABIBridge"),
        ], path: "Modules/Tests/NeoSimulatorAppTests", swiftSettings: [
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("InferIsolatedConformances"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        ]),
        .testTarget(name: "NeoSimulatorHostSupportTests", dependencies: [
            "NeoSimulatorKit", "NeoSimulatorHostSupport",
            .product(name: "ABIBridge", package: "ABIBridge"),
        ], path: "Modules/Tests/NeoSimulatorHostSupportTests"),
    ]
)
