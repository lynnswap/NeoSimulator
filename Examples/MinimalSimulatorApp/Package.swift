// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MinimalSimulatorApp",
    platforms: [.macOS("26.4")],
    dependencies: [.package(name: "NeoSimulatorKit", path: "../..")],
    targets: [
        .executableTarget(name: "MinimalSimulatorApp", dependencies: [
            .product(name: "NeoSimulatorKit", package: "NeoSimulatorKit"),
        ]),
    ]
)
