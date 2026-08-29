// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "xcode-simulator-host",
    platforms: [
        .macOS("26.4"),
    ],
    products: [
        .executable(
            name: "xcode-simulator-host",
            targets: ["XcodeSimulatorHost"]
        ),
        .executable(
            name: "XcodeSimulatorLegacyHost",
            targets: ["XcodeSimulatorLegacyHost"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.8.2"
        ),
    ],
    targets: [
        .executableTarget(
            name: "XcodeSimulatorHost",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "XcodeSimulatorLegacyHost",
            path: "Sources/XcodeSimulatorLegacyHost",
            exclude: ["Info.plist"],
            cSettings: [
                .unsafeFlags(["-fobjc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "XcodeSimulatorHostTests",
            dependencies: [
                "XcodeSimulatorHost",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
