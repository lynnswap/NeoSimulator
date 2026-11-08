// swift-tools-version: 6.4

import PackageDescription

// A consumer reads a member only through a module it imports, which keeps a lower target's opaque handles opaque.
let memberImportVisibility: [SwiftSetting] = [.enableUpcomingFeature("MemberImportVisibility")]

let package = Package(
    name: "NeoSimulatorKit",
    defaultLocalization: "en",
    platforms: [.macOS("26.4")],
    products: [
        // The supported SDK. The published API reference covers these two modules.
        .library(name: "NeoSimulatorKit", targets: ["NeoSimulatorKit"]),
        .library(name: "NeoSimulatorUI", targets: ["NeoSimulatorUI"]),
        // Implementation details that App/NeoSimulator.xcodeproj links. They are not a supported API: their only entry
        // points are `@_spi(AppBootstrap)`, for the application targets.
        .library(name: "NeoSimulatorApp", targets: ["NeoSimulatorApp"]),
        .library(name: "NeoSimulatorService", targets: ["NeoSimulatorService"]),
        // A diagnostic that CI runs.
        .executable(name: "CoreDeviceInventoryProbe", targets: ["CoreDeviceInventoryProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/lynnswap/ABIBridge.git", exact: "0.19.0"),
        .package(url: "https://github.com/lynnswap/ObservationBridge.git", exact: "0.15.11"),
    ],
    targets: [
        .target(name: "NeoSimulatorNative", dependencies: [
            .product(name: "ABIBridge", package: "ABIBridge"),
        ], swiftSettings: memberImportVisibility),
        .target(name: "NeoSimulatorDeviceIO", dependencies: [
            "NeoSimulatorNative",
            .product(name: "ABIBridge", package: "ABIBridge"),
        ], swiftSettings: memberImportVisibility),
        .target(name: "NeoSimulatorKit", dependencies: [
            "NeoSimulatorDeviceIO",
        ], swiftSettings: memberImportVisibility),
        .target(name: "NeoSimulatorPresentationAdapters", dependencies: [
            "NeoSimulatorKit", "NeoSimulatorDeviceIO", "NeoSimulatorNative",
            .product(name: "ABIBridge", package: "ABIBridge"),
            .product(name: "ObservationBridge", package: "ObservationBridge"),
        ], swiftSettings: memberImportVisibility),
        .target(name: "NeoSimulatorUI", dependencies: [
            "NeoSimulatorKit", "NeoSimulatorPresentationAdapters",
            .product(name: "ObservationBridge", package: "ObservationBridge"),
        ], swiftSettings: memberImportVisibility),
        .target(name: "NeoSimulatorHostSupport", dependencies: [
            "NeoSimulatorUI", "NeoSimulatorPresentationAdapters", "NeoSimulatorKit", "NeoSimulatorDeviceIO",
            .product(name: "ObservationBridge", package: "ObservationBridge"),
        ], swiftSettings: memberImportVisibility),
        // The manager's shared state and operations, below every pane of its window.
        .target(name: "NeoSimulatorManager", dependencies: [
            "NeoSimulatorHostSupport", "NeoSimulatorPresentationAdapters", "NeoSimulatorKit", "NeoSimulatorDeviceIO",
        ], swiftSettings: memberImportVisibility),
        // Physical devices' screen windows.
        .target(name: "NeoSimulatorCompactWindow", dependencies: [
            "NeoSimulatorHostSupport", "NeoSimulatorUI", "NeoSimulatorPresentationAdapters", "NeoSimulatorKit", "NeoSimulatorDeviceIO",
        ], swiftSettings: memberImportVisibility),
        // Open device screens, their placement, and device artwork, which the window's panes share.
        .target(name: "NeoSimulatorDeviceScreens", dependencies: [
            "NeoSimulatorCompactWindow", "NeoSimulatorManager", "NeoSimulatorHostSupport", "NeoSimulatorUI",
            "NeoSimulatorPresentationAdapters", "NeoSimulatorKit", "NeoSimulatorDeviceIO",
            .product(name: "ObservationBridge", package: "ObservationBridge"),
        ], swiftSettings: memberImportVisibility),
        .target(name: "NeoSimulatorApp", dependencies: [
            "NeoSimulatorDeviceScreens", "NeoSimulatorCompactWindow", "NeoSimulatorManager", "NeoSimulatorHostSupport", "NeoSimulatorUI", "NeoSimulatorPresentationAdapters", "NeoSimulatorKit", "NeoSimulatorDeviceIO",
            .product(name: "ObservationBridge", package: "ObservationBridge"),
        ], resources: [.process("Resources")], swiftSettings: memberImportVisibility),
        .target(name: "NeoSimulatorService", dependencies: [
            "NeoSimulatorHostSupport", "NeoSimulatorKit",
        ], swiftSettings: memberImportVisibility),
        .executableTarget(name: "CoreDeviceInventoryProbe", dependencies: ["NeoSimulatorKit"], swiftSettings: memberImportVisibility),
        .testTarget(name: "NeoSimulatorAppTests", dependencies: [
            "NeoSimulatorApp", "NeoSimulatorDeviceScreens", "NeoSimulatorCompactWindow", "NeoSimulatorManager", "NeoSimulatorService", "NeoSimulatorHostSupport", "NeoSimulatorUI",
            "NeoSimulatorPresentationAdapters", "NeoSimulatorKit", "NeoSimulatorDeviceIO",
            .product(name: "ABIBridge", package: "ABIBridge"),
        ], swiftSettings: [
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("InferIsolatedConformances"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        ]),
        .testTarget(name: "NeoSimulatorHostSupportTests", dependencies: [
            "NeoSimulatorHostSupport", "NeoSimulatorUI", "NeoSimulatorPresentationAdapters",
            "NeoSimulatorKit", "NeoSimulatorDeviceIO", "NeoSimulatorNative",
            .product(name: "ABIBridge", package: "ABIBridge"),
        ]),
    ]
)
