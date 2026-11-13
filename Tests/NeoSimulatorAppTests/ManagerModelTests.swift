import AppKit
import Foundation
@testable import NeoSimulatorApp
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
@testable import NeoSimulatorPresentationAdapters
@testable import NeoSimulatorService
import Observation
import SwiftUI
import Synchronization
import Testing
import IOSurface
@testable import NeoSimulatorManager
@testable import NeoSimulatorCompactWindow
@testable import NeoSimulatorDeviceScreens
@testable import NeoSimulatorInspector
@testable import NeoSimulatorDeviceDisplay
@testable import NeoSimulatorSidebar

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct ManagerModelTests {
    static func pairingDevice(paired: Bool, pairingState: String? = nil) throws -> InventoryDevice {
        let data = try JSONSerialization.data(withJSONObject: [
            "result": [
                "devices": [
                    [
                        "identifier": "remote",
                        "properties": [
                            "hardware": paired ? ["fidelity": "physical"] : [:],
                            "state": ["name": "Remote"],
                            "connection": [
                                "state": "disconnected",
                                "pairingState": pairingState ?? (paired ? "paired" : "unpaired")
                            ],
                        ],
                        "capabilities": [
                            [
                                "featureIdentifier": paired
                                    ? "com.apple.coredevice.feature.viewdevicescreen"
                                    : "com.apple.coredevice.feature.inititatepairing"
                            ]
                        ]
                    ]
                ]
            ]
        ])
        return .remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
    }

    /// Puts up `action`'s sheet about the first of two listed devices, then selects the second while it waits.
    func inspectorAskingAboutFirstDevice(action: String, page: DeviceInspectorModel.Page, content: DeviceInspectorModel.Content) async throws
        -> (source: ManagerModelSource, manager: SimulatorManagerModel, controller: ManagerDeviceInspectorController, window: NSWindow, sheet: NSWindow,
            first: InventoryDevice, second: InventoryDevice) {
        _ = NSApplication.shared
        let features: Set<String> = ["streamapplist", "uninstallapp", "configurationprofiles", "listFiles", "transferFiles", "processcontrol", "streamprocesslist"]
        let first = inspectedRemote("first-device", features: features)
        let second = inspectedRemote("second-device", features: features)
        let source = ManagerModelSource(devices: [], inspectorResponse:
            #"{"result":{"apps":[{"bundleIdentifier":"fixture.app","name":"Fixture","containerAccessible":true}],"configurationProfiles":[{"payloadIdentifier":"fixture.configuration","name":"Configuration"}],"files":[{"relativePath":"Fixture.ips","metadata":{},"resources":{"isDirectory":false}}]}}"#)
        await source.skipSettingsReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        let controller = ManagerDeviceInspectorController(model: manager, inspection: DeviceInspectorModel())
        // A sheet only needs a window to attach to; this one is never ordered on screen.
        let window = NSWindow(contentViewController: controller)
        manager.registry.apply(DeviceInventorySnapshot(devices: [first, second], issues: []))
        controller.setPage(page)
        controller.inspection.select(content)
        for device in [first, second] {
            manager.inspect(device, selectionCount: 1)
            let selectedDevice = try #require(manager.registry.device(for: device.id))
            controller.update(device: selectedDevice, isManaging: false, isVisible: true)
            #expect(await events.next() == .inspect(device.id))
            await finishInspectorRead(controller.inspection)
            guard device.id == first.id else { break }
            let table = try #require(inspectorViews(controller.view).compactMap { $0 as? NSTableView }.first {
                $0.accessibilityLabel() == "Installed Applications, Profiles, and Reports"
            })
            try await wait(timeout: .seconds(5)) { table.numberOfRows == 1 }
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            #expect(NSApp.sendAction(NSSelectorFromString(action), to: controller, from: nil))
            try await wait(timeout: .seconds(5)) { window.attachedSheet != nil }
        }
        return (source, manager, controller, window, try #require(window.attachedSheet), first, second)
    }

    static let inspectionResponse = #"{"result":{"properties":{"name":"Details"},"apps":[{"bundleIdentifier":"fixture.app","name":"Fixture"}],"configurationProfiles":[{"payloadIdentifier":"fixture.configuration","name":"Configuration"}],"provisioningProfiles":[{"uuid":"fixture.provisioning","name":"Provisioning"}],"files":[{"relativePath":"Fixture.ips","metadata":{},"resources":{"isDirectory":false}}]}}"#

    func inspectedRemote(
        _ identifier: String = "inspected-device", connection: String = "connected", pairingState: String = "paired",
                                 features: Set<String> = ["streamapplist", "configurationprofiles", "provisioningprofiles", "listFiles"]) -> InventoryDevice {
        .remote(CoreDeviceDevice(identifier: identifier, udid: nil, kind: .physical, name: identifier, reportedName: identifier,
            modelIdentifier: nil, modelName: nil, cpuType: nil, platform: "iOS", osVersion: nil, osBuild: nil, osBuildUpdate: nil,
                connectionState: connection, pairingState: pairingState, transportType: nil, bootState: "booted",
                preparednessState: nil,
            capabilities: Set(features.map { "com.apple.coredevice.feature." + $0 }), lastConnectedAt: nil, visibilityClass: nil))
    }

    func applications(_ names: String...) -> String {
        #"{"result":{"apps":["# + names.map { #"{"bundleIdentifier":"fixture.\#($0)","name":"\#($0)"}"# }.joined(separator: ",") + "]}}"
    }

    func listing(_ device: InventoryDevice..., response: String = ManagerModelTests.inspectionResponse) -> (ManagerModelSource, DeviceRegistry) {
        let source = ManagerModelSource(devices: [], inspectorResponse: response)
        let registry = DeviceRegistry(source: source)
        registry.apply(DeviceInventorySnapshot(devices: device, issues: []))
        return (source, registry)
    }

    func finishInspectorRead(_ inspection: DeviceInspectorModel) async {
        while inspection.reading {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = inspection.reading } onChange: { continuation.resume() }
            }
        }
    }

    func inspectorViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(inspectorViews)
    }

    /// A read that reports its process identifier to the returned task and then never exits by itself.
    func unresponsiveRead(in directory: URL) throws -> (command: SystemCommand, identifier: Task<Int32?, any Error>) {
        let ready = directory.appending(path: "ready-\(UUID().uuidString)")
        try #require(mkfifo(ready.path, 0o600) == 0)
        let identifier = Task {
            let data = try await performBlockingIO { try FileHandle(forReadingFrom: ready).readToEnd() ?? Data() }
            return Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (SystemCommand(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' \"$$\" > \"$1\"; exec /bin/sleep 300", "fixture", ready.path], policy: .cancellable), identifier)
    }

    /// A registry with `devices`, and the first device's model, whose settings stay current while the test runs.
    func settingsFixture(_ source: ManagerModelSource) async throws -> (registry: DeviceRegistry, model: DeviceModel, interest: DeviceReadInterest) {
        let registry = DeviceRegistry(source: source)
        try await registry.refresh()
        let model = try #require(registry.devices.first)
        return (registry, model, model.keepCurrent(.settings))
    }

    /// What a screen does as it connects: it reports its own record of the device, and shows the model it gets back.
    func connectScreen(_ registry: DeviceRegistry, booted: Bool, name: String = "Test Phone", lastBootDate: Date? = nil) -> DeviceModel {
        let record = AvailableDevice(identifier: "same-udid", name: name, descriptiveName: name, runtimeIdentifier: "test-runtime",
                                     runtimeName: "iOS", productFamily: 1, deviceTypeName: "Phone", state: booted ? 3 : 1, deviceSetPath: nil)
        return registry.presentedModel(of: record, lastBootDate: lastBootDate, ownerXcodeURL: URL(fileURLWithPath: "/Screen Xcode.app"),
            channel: SimulatorDeviceChannel(scope: .device(DeviceAddress(identifier: "same-udid", deviceSetPath: nil))))
    }

    func awaitServiceOperations(_ manager: SimulatorManagerModel) async throws {
        try await wait(timeout: .seconds(5)) {
            !manager.isBusy && manager.activity.isEmpty && manager.managingDeviceIDs.isEmpty
                && !manager.registry.devices.contains { $0.backgroundServices.isChanging }
        }
    }

    struct LegacyServiceProfiles: Encodable {
        struct Binding: Encodable {
            let profileID: UUID
            let base: ServiceConfiguration
            let overrides: [String: Bool]
            let requestID: UUID
            let pendingApplication: Bool
        }
        let profiles: [ServiceProfile.Record]
        let devices: [DeviceInventoryID: Binding]
    }

    func serviceProfileURL(_ domain: String) -> URL {
        URL.temporaryDirectory.appending(path: domain, directoryHint: .isDirectory)
            .appending(path: "ServiceProfiles.json")
    }

    func simulator(deviceSet: String? = nil, name: String = "Test Phone", state: String = "Booted",
                           lastUsedAt: Date? = nil, lastBootDate: Date? = nil, createdAt: Date? = nil) -> InventoryDevice {
        .simulator(SimulatorHostDevice(identifier: "same-udid", name: name, descriptiveName: name,
            runtimeIdentifier: "test-runtime", runtimeName: "iOS", productFamily: "iPhone", state: state,
            deviceSetPath: deviceSet, lastUsedAt: lastUsedAt, lastBootDate: lastBootDate, createdAt: createdAt, capabilities: ["com.apple.dt.coredevice.device.shutdown"]))
    }

    func settings(appearance: DeviceAppearance, contentSize: DeviceContentSize? = nil) -> SimulatorDeviceSettings {
        SimulatorDeviceSettings(appearance: appearance, contentSize: contentSize)
    }
}
