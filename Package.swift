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
        .executable(name: "CoreDeviceInventoryProbe", targets: ["CoreDeviceInventoryProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/lynnswap/ABIBridge.git", exact: "0.16.3"),
        .package(url: "https://github.com/lynnswap/ObservationBridge.git", exact: "0.15.8"),
    ],
    targets: [
        .target(name: "NeoSimulatorDeviceIO"),
        .target(
            name: "NeoSimulatorKit",
            dependencies: [
                "NeoSimulatorDeviceIO",
                .product(name: "ABIBridge", package: "ABIBridge"),
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ]
        ),
        .target(name: "NeoSimulatorHostSupport", dependencies: [
            "NeoSimulatorDeviceIO", "NeoSimulatorKit",
            .product(name: "ABIBridge", package: "ABIBridge"),
            .product(name: "ObservationBridge", package: "ObservationBridge"),
        ]),
        .target(name: "NeoSimulatorApp", dependencies: [
            "NeoSimulatorDeviceIO", "NeoSimulatorKit", "NeoSimulatorHostSupport",
            .product(name: "ObservationBridge", package: "ObservationBridge"),
        ], resources: [.process("Resources")]),
        .target(name: "NeoSimulatorService", dependencies: [
            "NeoSimulatorKit", "NeoSimulatorHostSupport",
        ]),
        .executableTarget(name: "CoreDeviceInventoryProbe", dependencies: ["NeoSimulatorHostSupport"]),
        .testTarget(name: "NeoSimulatorAppTests", dependencies: [
            "NeoSimulatorApp", "NeoSimulatorDeviceIO", "NeoSimulatorKit", "NeoSimulatorHostSupport", "NeoSimulatorService",
            .product(name: "ABIBridge", package: "ABIBridge"),
        ], swiftSettings: [
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("InferIsolatedConformances"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        ]),
        .testTarget(name: "NeoSimulatorHostSupportTests", dependencies: [
            "NeoSimulatorDeviceIO", "NeoSimulatorKit", "NeoSimulatorHostSupport",
            .product(name: "ABIBridge", package: "ABIBridge"),
        ]),
    ]
)
