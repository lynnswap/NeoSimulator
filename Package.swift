// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "xcode-simulator-host",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "xcode-simulator-host",
            targets: ["xcode_simulator_host"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "xcode_simulator_host",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "xcode_simulator_hostTests",
            dependencies: ["xcode_simulator_host"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
