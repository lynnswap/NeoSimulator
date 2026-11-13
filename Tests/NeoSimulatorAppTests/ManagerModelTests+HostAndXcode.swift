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
    @Test func launchAppliesThePreferenceAndQuitEndsTheSession() async throws {
        let source = ManagerModelSource(devices: [])
        let manager = SimulatorManagerModel(source: source)
        let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).plist")
        let access = HostPreferenceAccess(file: file, chooseFile: { _, _ in
            Issue.record("Device Hub has not created a settings file to select.")
            return nil
        })
        manager.requestHostPreferenceAccess = { try await access.request() }
        manager.start()
        try await manager.quitRenderer(keepingDevicesRunning: true)
        #expect(await source.sessionEvents == ["begin", "status", "quit", "end"])
    }

    @Test func aFailedLaunchStillExposesThePreferredHostForRetry() async throws {
        let source = ManagerModelSource(devices: [])
        await source.failSessionStart()
        let manager = SimulatorManagerModel(source: source)
        var reported = false
        manager.onError = { _ in reported = true }
        manager.start()
        try await manager.prepareForQuit()
        #expect(reported)
        #expect(manager.status?.host == .deviceHub)
    }

    @Test(arguments: [false, true])
    func failedExitPreparationKeepsTheSessionAvailableForAnotherAttempt(endingSession: Bool) async throws {
        let source = ManagerModelSource(devices: [])
        let manager = SimulatorManagerModel(source: source)
        manager.start()
        if endingSession { await source.failNextSessionEnd() }
        do {
            try await manager.quitRenderer(keepingDevicesRunning: true) {
                if !endingSession { throw ManagerModelSource.Failure.unavailable }
            }
            Issue.record("Exit preparation should have failed")
        } catch ManagerModelSource.Failure.unavailable {}
        if endingSession {
            #expect(await source.sessionEvents.suffix(2) == ["end", "begin"])
        } else {
            #expect(await !source.sessionEvents.contains("end"))
        }
        try await manager.quitRenderer(keepingDevicesRunning: true)
        #expect(await source.sessionEvents.last == "end")
    }

    @Test func quittingStopsTheAcceptedMoveAndWaitsForIt() async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"}}},{"identifier":"B","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"B"}}}]}}"#.utf8))
        let a = try #require(devices.first), b = try #require(devices.last)
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: devices.map(InventoryDevice.remote)))
        model.registry.stopReading()
        await model.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        let pane = main.deviceScreenViewController
        defer { main.window?.close() }
        let aTransport = TestRemoteScreenTransport()
        let aSession = RemoteDeviceScreenSession(device: a) { _, _, _ in aTransport }
        let bSession = RemoteDeviceScreenSession(device: b) { _, _, _ in TestRemoteScreenTransport() }
        try await aSession.start()
        try await bSession.start()
        let aController = RemoteDeviceWindowController(device: a, session: aSession, presentCompactWindow: { _ in })
        let bController = RemoteDeviceWindowController(device: b, session: bSession, presentCompactWindow: { _ in })
        let aID = DeviceInventoryID.coreDevice(a.identifier)
        app.screens.attach(aController)
        app.screens.attach(bController)
        main.selectDevice(aID)
        try await main.presentConnectedScreen(aID, purpose: .requested)
        let releasing = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        var releases = releasing.stream.makeAsyncIterator()
        aTransport.onReleaseInputs = {
            aTransport.onReleaseInputs = nil
            releasing.continuation.yield(())
            var permits = resume.stream.makeAsyncIterator()
            _ = await permits.next()
        }
        let content = try #require(main.window?.contentView)
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        let bRow = try #require((0..<outline.numberOfRows).first { row in
            row != outline.selectedRow && outline.item(atRow: row).map { main.sidebar.outlineView(outline, shouldSelectItem: $0) } == true
        })
        outline.selectRowIndexes(IndexSet(integer: bRow), byExtendingSelection: false)
        #expect(await releases.next() != nil)
        app.screens.beginQuitting()
        resume.continuation.yield(())
        await pane.waitForScreenMoves()
        #expect(!aController.isEmbedded && !bController.isEmbedded && pane.liveDeviceIdentifier == nil)
        #expect(aSession.state == .connected && bSession.state == .connected)
        try await aSession.stop()
        try await bSession.stop()
    }

    @Test func aHostOperationFollowsAcceptedWritesAndHoldsLaterOnesOfItsDevice() async throws {
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let source = ManagerModelSource(devices: [first, second])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.setDeviceSetting(.appearance(.dark), for: first.id)
        #expect(await events.next() == .write(first.id))
        manager.closeDevice(first.id, keepingDeviceRunning: true, after: Task {})
        #expect(!manager.canEditSettings(for: first.id) && manager.canEditSettings(for: second.id))
        // The close waits for the edit accepted before it. The edit accepted after it waits for the close.
        manager.setDeviceSetting(.boldText(true), for: first.id)
        manager.setDeviceSetting(.boldText(true), for: second.id)
        #expect(await events.next() == .write(second.id))
        await source.completeWrite(for: second.id)
        #expect(await events.next() == .read(second.id))
        await source.completeRead(SimulatorDeviceSettings(boldText: true), for: second.id)
        await source.completeWrite(for: first.id)
        // The finished edit's read does not wait for what follows it, which stays in order.
        let started = [await events.next(), await events.next(), await events.next()]
        #expect(started.filter { $0 != .read(first.id) } == [.close(first.id), .write(first.id)])
        await source.completeRead(SimulatorDeviceSettings(appearance: .dark), for: first.id)
        await source.completeWrite(for: first.id)
        #expect(await events.next() == .read(first.id))
        await source.completeRead(SimulatorDeviceSettings(appearance: .dark, boldText: true), for: first.id)
        try await manager.prepareForQuit()
    }
}
