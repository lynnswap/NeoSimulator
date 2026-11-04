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
            path: ".",
            exclude: [
                "App/NeoSimulator/Simulator/Commands/MenuController.swift",
                "App/NeoSimulator/Simulator/Hosting/HostApplication.swift",
                "App/NeoSimulator/Simulator/Hosting/RendererRequest.swift",
                "App/NeoSimulator/Simulator/Hosting/RendererOwnerIdentity.swift",
            ],
            sources: [
                "Modules/Sources/NeoSimulatorKit",
                "App/NeoSimulator/Simulator",
                "App/NeoSimulator/DeviceDisplay/DeviceCanvasControls.swift",
                "App/NeoSimulator/DeviceDisplay/Layout",
                "App/NeoSimulator/DeviceInput/Keyboard",
                "App/NeoSimulator/DeviceAppearance/Symbols",
                "App/NeoSimulator/DeviceBrowser/Creation/SimulatorCatalog.swift",
                "App/NeoSimulator/App/Errors",
            ]
        ),
        .testTarget(name: "XcodeSimulatorHostTests", dependencies: ["XcodeSimulatorHost"]),
    ]
)
