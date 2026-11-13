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

extension ManagerModelTests {
    // `install:` reaches the same call the same way, but its open panel has no URL until a person picks a file.
    @Test(arguments: [
        ("remove:", DeviceInspectorModel.Page.info, DeviceInspectorModel.Content.applications, ["device", "uninstall", "app", "fixture.app"]),
        ("remove:", .info, .configuration, ["device", "profile", "remove", "fixture.configuration"]),
        ("downloadReport:", .reports, .info, ["device", "copy", "from", "--domain-type", "systemCrashLogs", "--source", "Fixture.ips"]),
        ("exportData:", .info, .applications, ["device", "copy", "from", "--source", "."]),
        ("importData:", .info, .applications, ["device"]),
    ])
    func aChangeConfirmedAfterTheSelectionMovesActsOnTheDeviceItAskedAbout(
        change: (action: String, page: DeviceInspectorModel.Page, content: DeviceInspectorModel.Content, command: [String])) async throws {
        let (source, manager, controller, window, sheet, first, _) = try await inspectorAskingAboutFirstDevice(
            action: change.action, page: change.page, content: change.content)
        var events = source.events.makeAsyncIterator()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "Chosen"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await source.holdInspectorReads()
        if let panel = sheet as? NSSavePanel {
            panel.directoryURL = directory
            panel.nameFieldStringValue = "Chosen"
            window.endSheet(panel, returnCode: .OK)
        } else { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        if change.action == "importData:" {
            try await wait(timeout: .seconds(5)) { window.attachedSheet != nil && window.attachedSheet !== sheet }
            window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        }
        try await wait(timeout: .seconds(5)) { !manager.managingDeviceIDs.isEmpty }
        try #require(manager.managingDeviceIDs == [first.id])
        #expect(await events.next() == .inspect(first.id))
        let command = try #require(await source.inspectorCommands.last).arguments
        #expect(command.starts(with: change.command))
        #expect(command.contains("first-device") && !command.contains("second-device"))
        await source.failInspectorRead()
        try await wait(timeout: .seconds(5)) { manager.managingDeviceIDs.isEmpty }
        controller.update(device: nil, isManaging: false, isVisible: true)
    }

    @Test func aDeviceRetiredWhileItsSheetWasUpRejectsTheConfirmedChange() async throws {
        let (source, manager, controller, window, sheet, _, second) = try await inspectorAskingAboutFirstDevice(
            action: "remove:", page: .info, content: .applications)
        var failures: [String] = []
        manager.onError = { failures.append($0.localizedDescription) }
        manager.registry.apply(DeviceInventorySnapshot(devices: [second], issues: []))
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await wait(timeout: .seconds(5)) { !failures.isEmpty }
        #expect(failures == ["first-device: This device is no longer available."])
        #expect(await source.inspectorCommands.allSatisfy { !$0.arguments.contains("uninstall") })
        try await wait(timeout: .seconds(5)) { manager.managingDeviceIDs.isEmpty }
        controller.update(device: nil, isManaging: false, isVisible: true)
    }

    @Test func cancellingAQuitRestoresTheInstallerOfAnApplicationListThatCannotBeRead() async throws {
        _ = NSApplication.shared
        let device = inspectedRemote(features: ["installapp"])
        let source = ManagerModelSource(devices: [], inspectorResponse: Self.inspectionResponse)
        await source.skipSettingsReads()
        let manager = SimulatorManagerModel(source: source)
        let controller = ManagerDeviceInspectorController(model: manager, inspection: DeviceInspectorModel())
        // A quit can be cancelled before the inspector was ever shown.
        controller.resumeAfterCancelledQuit()
        #expect(!controller.isViewLoaded)

        manager.registry.apply(DeviceInventorySnapshot(devices: [device], issues: []))
        manager.inspect(device, selectionCount: 1)
        controller.setPage(.info)
        controller.inspection.select(.applications)
        let selectedDevice = try #require(manager.registry.device(for: device.id))
        controller.update(device: selectedDevice, isManaging: false, isVisible: true)
        let install = try #require(inspectorViews(controller.view).compactMap { $0 as? NSButton }.first { $0.toolTip == "Install…" })
        #expect(install.isEnabled && !install.isHidden)

        try await controller.finishPreviews()
        #expect(!install.isEnabled)
        controller.resumeAfterCancelledQuit()
        #expect(install.isEnabled)
        #expect(await source.inspectorCommands.isEmpty)
        controller.update(device: nil, isManaging: false, isVisible: true)
    }
}
