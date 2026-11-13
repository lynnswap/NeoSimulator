import ABIBridge
import AppKit
import Darwin
import IOKit.hidsystem
@testable import NeoSimulatorApp
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
@testable import NeoSimulatorPresentationAdapters
@testable import NeoSimulatorService
@testable import NeoSimulatorUI
import Observation
import Synchronization
import Testing
import SwiftUI
import Combine
import XCTest
import XPC
@testable import NeoSimulatorManager
@testable import NeoSimulatorInspector
@testable import NeoSimulatorDeviceDisplay
@testable import NeoSimulatorCompactWindow
@testable import NeoSimulatorDeviceScreens

extension SimulatorHostTests {
    @Test func editMenuEndsWithSimulatorAppsPasteboardCommands() throws {
        _ = NSApplication.shared
        MenuController(application: nil).install()
        defer { NSApp.mainMenu = nil }
        let edit = try #require(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        #expect(edit.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
            "Undo", "Redo", "-", "Cut", "Copy", "Copy Screen", "Paste", "Select All", "-",
            "Automatically Sync Pasteboard", "Get Pasteboard", "Send Pasteboard",
        ])
        #expect(edit.items.suffix(3).allSatisfy { $0.keyEquivalent.isEmpty })
    }

    @Test func automaticPasteboardSyncIsOnUnlessTurnedOff() throws {
        _ = NSApplication.shared
        // Simulator.app also registers PasteboardAutomaticSync on. A saved
        // choice takes precedence over the registered value when read again.
        let domain = "NeoSimulatorTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        HostPreferences.registerDefaults()
        let sync = PasteboardSync(preferences: preferences) { [] }
        #expect(sync.isOn)
        let menu = MenuController(application: nil, pasteboardSync: sync)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let edit = try #require(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        let item = try #require(edit.items.first { $0.title == "Automatically Sync Pasteboard" })
        let action = try #require(item.action)
        #expect(menu.validateMenuItem(item))
        #expect(item.state == .on)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(!sync.isOn)
        #expect(menu.validateMenuItem(item))
        #expect(item.state == .off)
        #expect(!PasteboardSync(preferences: preferences) { [] }.isOn)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(sync.isOn)
        // Saved, so the choice does not depend on the registered default.
        #expect(preferences.persistentDomain(forName: domain)?[HostPreferences.pasteboardAutomaticSync] as? Bool == true)
        #expect(menu.validateMenuItem(item))
        #expect(item.state == .on)
        #expect(!MenuController(application: nil).validateMenuItem(item))
    }

    @Test func pasteboardTransfersNeedADeviceThatExchangesItsPasteboard() throws {
        let get = DeviceCommand.command(.getPasteboard), send = DeviceCommand.command(.sendPasteboard)
        func availability(_ family: DeviceCapabilities.Family, features: Set<String> = [DeviceCapabilities.pasteboard],
                          _ change: (DeviceWindowController, TestDisplay) -> Void = { _, _ in }) throws -> [Bool] {
            let display = TestDisplay()
            let controller = try makeController(display, family: family, features: features)
            defer { controller.invalidate() }
            change(controller, display)
            return [get, send].flatMap { [$0.isSupported(controller.session.capabilities), $0.isEnabled(controller)] }
        }
        for family in [DeviceCapabilities.Family.iPhone, .iPad, .vision] {
            #expect(try availability(family) == [true, true, true, true])
        }
        for family in [DeviceCapabilities.Family.tv, .watch] {
            #expect(try availability(family) == [true, false, true, false])
        }
        #expect(try availability(.iPhone, features: []) == [true, false, true, false])
        #expect(try availability(.iPhone) { $1.isBooted = false } == [true, false, true, false])
        #expect(try availability(.iPhone) { controller, _ in controller.session.disconnect() } == [true, false, true, false])
    }

    @Test func pasteboardTransfersConnectOnlyWhenChosen() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let display = TestDisplay()
        let controller = try makeController(display, features: [DeviceCapabilities.pasteboard], pasteboard: pasteboard)
        defer { controller.invalidate() }
        #expect(display.pasteboards.isEmpty)
        controller.perform(.getPasteboard)
        controller.perform(.sendPasteboard)
        controller.perform(.getPasteboard)
        let connection = try #require(display.pasteboards.first)
        #expect(display.pasteboards.count == 1)
        #expect(connection.pasteboard === pasteboard)
        #expect(connection.transfers == [.get, .send, .get])
        #expect(connection.automaticSync == [false])
        // Keep the connection alive for lazy reads from the Mac pasteboard.
        #expect(!connection.isDisconnected)
        controller.invalidate()
        #expect(connection.isDisconnected)
    }

    @Test func pasteboardTransferFailuresReachTheirCommand() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let display = TestDisplay()
        let session = try makeSession(display, features: [DeviceCapabilities.pasteboard], pasteboard: pasteboard)
        defer { session.disconnect() }
        var failures: [String] = []
        func transfer(_ transfer: PasteboardTransfer) {
            session.transferPasteboard(transfer) { failures.append($0.localizedDescription) }
        }
        let get = "Could not get the simulator's pasteboard: "
        let send = "Could not send the pasteboard to the simulator: "
        let closed = "The simulator closed its pasteboard connection."

        display.pasteboardError = SimulatorError.operation("Unable to lookup in current state: Shutdown")
        transfer(.get)
        #expect(failures == [get + "Unable to lookup in current state: Shutdown"])
        #expect(display.pasteboards.isEmpty)

        // The first activation belongs to the connection; later activations complete pushes.
        transfer(.send)
        let first = try #require(display.pasteboards.first)
        first.send(.activated)
        first.send(.activated)
        transfer(.get)
        first.send(.failedToApply(SimulatorError.operation("pasteboard communication failure")))
        #expect(failures.last == get + "pasteboard communication failure")
        transfer(.get)
        first.send(.applied(generation: 1))
        first.send(.lostConnection)
        #expect(failures.count == 2)
        #expect(first.isDisconnected)

        transfer(.send)
        let second = try #require(display.pasteboards.last)
        #expect(display.pasteboards.count == 2)
        second.send(.activated)
        transfer(.get)
        second.send(.lostConnection)
        #expect(Set(failures.dropFirst(2)) == [send + closed, get + closed])
        transfer(.send)
        #expect(display.pasteboards.count == 3)
    }

    @Test func pasteboardDelegateAnswersSimPasteboardPlus() async throws {
        let runtime = try await makeRuntime()
        #expect(runtime.pasteboard.serviceName == "com.apple.CoreSimulator.SimPasteboardInterface")
        // Optional protocol callbacks must match the private Objective-C declarations.
        let delegateProtocol = try #require(objc_getProtocol("_TtP17SimPasteboardPlus21SimPasteboardDelegate_"))
        var events: [String] = []
        let delegate = SimulatorPasteboardDelegate { events.append("\($0)") }
        let interface = NSObject(), host = NSUUID(), pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let callbacks: [(String, () -> Void)] = [
            ("simPasteboardDidBecomeActive:", { delegate.simPasteboardDidBecomeActive(interface) }),
            ("simPasteboardDidLoseConnection:", { delegate.simPasteboardDidLoseConnection(interface) }),
            ("simPasteboardDidApplySnapshot:fromHost:incomingGeneration:toPasteboard:atGeneration:", {
                delegate.simPasteboardDidApplySnapshot(interface, fromHost: host, incomingGeneration: 7,
                                                       toPasteboard: pasteboard, atGeneration: 2)
            }),
            ("simPasteboardErrorApplyingSnapshot:fromHost:generation:error:toPasteboard:", {
                delegate.simPasteboardErrorApplyingSnapshot(interface, fromHost: host, generation: 7,
                                                            error: NSError(domain: "CFPasteboardErrorDomain", code: -25130),
                                                            toPasteboard: pasteboard)
            }),
            ("simPasteboardDidChangeAutoNotifyState:forPasteboard:toStatus:", {
                delegate.simPasteboardDidChangeAutoNotifyState(interface, forPasteboard: pasteboard, toStatus: true)
            }),
        ]
        for (name, call) in callbacks {
            let selector = NSSelectorFromString(name)
            let declared = protocol_getMethodDescription(delegateProtocol, selector, false, true)
            let method = try #require(class_getInstanceMethod(SimulatorPasteboardDelegate.self, selector), "\(name)")
            #expect(declared.types.map { String(cString: $0) } == String(cString: method_getTypeEncoding(method)!))
            call()
        }
        #expect(events.count == 5)
        #expect(events.prefix(3) == ["activated", "lostConnection", "applied(generation: 2)"])
        #expect(events[3].hasPrefix("failedToApply"))
        #expect(events.last == "synchronizationChanged(true)")
    }

    @Test func devicesConnectingWhileSynchronizingReceiveTheMacPasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: MemoryPreferences()) { sessions }
        func start(_ family: DeviceCapabilities.Family = .iPhone, features: Set<String> = [DeviceCapabilities.pasteboard],
                   _ change: (TestDisplay) -> Void = { _ in }) throws -> (DeviceSession, TestDisplay) {
            let display = TestDisplay()
            change(display)
            let session = try makeSession(display, family: family, features: features, pasteboard: pasteboard,
                                          pasteboardSync: sync)
            sessions.append(session)
            session.startPasteboardSync()
            return (session, display)
        }
        defer { sessions.forEach { $0.disconnect() } }

        #expect(try start().1.pasteboards.isEmpty)

        sync.toggle()
        let (session, display) = try start()
        let connection = try #require(display.pasteboards.first)
        #expect(display.pasteboards.count == 1)
        #expect(connection.pasteboard === pasteboard)
        #expect(connection.automaticSync == [true])
        #expect(connection.transfers == [.send])
        #expect(!session.canTransferPasteboard)
        session.transferPasteboard(.get) { _ in Issue.record("no transfer") }
        #expect(connection.transfers == [.send])
        #expect(try start(.tv).1.pasteboards.isEmpty)
        #expect(try start(features: []).1.pasteboards.isEmpty)
        #expect(try start { $0.isBooted = false }.1.pasteboards.isEmpty)
    }

    @Test func turningPasteboardSyncOnAndOffReachesEveryDevice() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: MemoryPreferences()) { sessions }
        func add(_ family: DeviceCapabilities.Family) throws -> (DeviceSession, TestDisplay) {
            let display = TestDisplay()
            let session = try makeSession(display, family: family, features: [DeviceCapabilities.pasteboard],
                                          pasteboard: pasteboard, pasteboardSync: sync)
            sessions.append(session)
            return (session, display)
        }
        let (phone, phoneDisplay) = try add(.iPhone)
        let (pad, padDisplay) = try add(.iPad)
        let (_, tvDisplay) = try add(.tv)
        defer { sessions.forEach { $0.disconnect() } }
        phone.transferPasteboard(.get) { _ in }
        let phoneConnection = try #require(phoneDisplay.pasteboards.first)

        sync.toggle()
        #expect(phoneConnection.automaticSync == [false, true])
        let padConnection = try #require(padDisplay.pasteboards.first)
        #expect(padConnection.automaticSync == [true])
        #expect(padConnection.transfers.isEmpty)
        #expect(tvDisplay.pasteboards.isEmpty)
        #expect(!phone.canTransferPasteboard && !pad.canTransferPasteboard)

        sync.toggle()
        #expect(phoneConnection.automaticSync == [false, true, false])
        #expect(padConnection.automaticSync == [true, false])
        #expect(!phoneConnection.isDisconnected && !padConnection.isDisconnected)
        #expect(phoneConnection.transfers == [.get])
        #expect(padConnection.transfers.isEmpty)
        #expect(phone.canTransferPasteboard && pad.canTransferPasteboard)
        #expect(phoneDisplay.pasteboards.count == 1 && padDisplay.pasteboards.count == 1)
    }

    @Test func aPasteboardConnectionThatArrivesAfterTheSessionEndedIsLetGo() async throws {
        let display = TestDisplay()
        let worker = HeldDeviceWorker()
        defer { worker.release() }
        let session = try makeSession(display, features: Self.defaultFeatures.union([DeviceCapabilities.pasteboard]))
        display.worker = worker
        worker.hold()
        var failures: [String] = []
        session.transferPasteboard(.get) { failures.append($0.localizedDescription) }
        session.transferPasteboard(.send) { failures.append($0.localizedDescription) }
        try await wait { worker.calls.count == 1 }
        session.disconnect()
        worker.release()
        try await wait { display.pasteboards.count == 1 && failures.count == 2 }
        #expect(display.pasteboards[0].isDisconnected && display.pasteboards[0].transfers.isEmpty)
        #expect(worker.calls == ["connect the device's pasteboard"])
    }

    @Test func aPasteboardActivationWhileConnectingIsTheFirstSoTheNextCompletesThePush() async throws {
        let display = TestDisplay()
        let worker = HeldDeviceWorker()
        defer { worker.release() }
        let session = try makeSession(display, features: [DeviceCapabilities.pasteboard])
        defer { session.disconnect() }
        display.worker = worker
        worker.hold()
        var failures: [String] = []
        session.transferPasteboard(.send) { failures.append($0.localizedDescription) }
        try await wait { worker.calls == ["connect the device's pasteboard"] }

        // The interface reports on the main queue while the worker is still returning it.
        let events = try #require(display.connectingPasteboardEvents)
        events(.activated)
        worker.release()
        try await wait { display.pasteboards.first?.transfers == [.send] }
        let connection = display.pasteboards[0]
        connection.send(.activated)
        connection.send(.lostConnection)
        #expect(failures.isEmpty)
    }

    @Test func aPasteboardConnectionThatClosesWhileConnectingIsNotKeptAndTheNextStartsAfresh() async throws {
        let display = TestDisplay()
        let worker = HeldDeviceWorker()
        defer { worker.release() }
        let session = try makeSession(display, features: [DeviceCapabilities.pasteboard])
        defer { session.disconnect() }
        display.worker = worker
        worker.hold()
        var failures: [String] = []
        session.transferPasteboard(.send) { failures.append($0.localizedDescription) }
        try await wait { worker.calls == ["connect the device's pasteboard"] }

        let events = try #require(display.connectingPasteboardEvents)
        events(.lostConnection)
        worker.release()
        try await wait { failures.count == 1 }
        #expect(failures == ["Could not send the pasteboard to the simulator: The simulator closed its pasteboard connection."])
        #expect(display.pasteboards.count == 1)
        #expect(display.pasteboards[0].isDisconnected && display.pasteboards[0].transfers.isEmpty)

        failures = []
        session.transferPasteboard(.send) { failures.append($0.localizedDescription) }
        try await wait { display.pasteboards.last?.transfers == [.send] }
        #expect(display.pasteboards.count == 2)
        let next = display.pasteboards[1]
        next.send(.activated)
        next.send(.activated)
        next.send(.lostConnection)
        #expect(failures.isEmpty)
    }

    @Test func aSynchronizedPasteboardThatClosesWhileConnectingConnectsAgain() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.pasteboardAutomaticSync] = true
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: preferences) { sessions }
        let display = TestDisplay()
        let worker = HeldDeviceWorker()
        defer { worker.release() }
        let session = try makeSession(display, features: [DeviceCapabilities.pasteboard], pasteboard: pasteboard,
                                      pasteboardSync: sync)
        sessions.append(session)
        defer { session.disconnect() }
        display.worker = worker
        worker.hold()
        session.updatePasteboardSync()
        try await wait { worker.calls == ["connect the device's pasteboard"] }

        // What applied before the connection arrived still counts, unlike the connection itself once it has closed.
        let events = try #require(display.connectingPasteboardEvents)
        events(.applied(generation: pasteboard.changeCount))
        events(.lostConnection)
        worker.release()
        try await wait { display.pasteboards.count == 2 && display.pasteboards[1].automaticSync == [true] }
        #expect(display.pasteboards[0].isDisconnected)
        #expect(!display.pasteboards[1].isDisconnected)
        session.sendSynchronizedPasteboard()
        #expect(display.pasteboards[1].transfers.isEmpty)
    }

    @Test func aPasteboardConnectionThatFailedAsksForNothingWhenItCloses() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.pasteboardAutomaticSync] = true
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: preferences) { sessions }
        let display = TestDisplay()
        let session = try makeSession(display, features: [DeviceCapabilities.pasteboard], pasteboard: pasteboard,
                                      pasteboardSync: sync)
        sessions.append(session)
        defer { session.disconnect() }
        display.pasteboardError = SimulatorError.operation("Unable to lookup in current state: Shutdown")
        session.updatePasteboardSync()
        #expect(display.pasteboardConnectionAttempts == 1)
        let abandoned = try #require(display.connectingPasteboardEvents)

        abandoned(.lostConnection)
        #expect(display.pasteboardConnectionAttempts == 1)
        session.updatePasteboardSync()
        #expect(display.pasteboardConnectionAttempts == 2)
        #expect(display.pasteboards.count == 1 && !display.pasteboards[0].isDisconnected)
    }

    @Test func whatAPasteboardConnectionGivenUpOnStillReportsLeavesTheNextAlone() async throws {
        let display = TestDisplay()
        let worker = HeldDeviceWorker(limit: .milliseconds(50))
        defer { worker.release() }
        let model = standaloneDeviceModel()
        model.follow(worker.channel)
        let session = try makeSession(display, features: [DeviceCapabilities.pasteboard], model: model)
        defer { session.disconnect() }
        display.worker = worker
        worker.hold()
        var failures: [String] = []
        session.transferPasteboard(.send) { failures.append($0.localizedDescription) }
        try await wait { failures.count == 1 && model.unresponsiveOperation != nil }
        let abandoned = try #require(display.connectingPasteboardEvents)
        worker.release()
        try await wait { model.unresponsiveOperation == nil }

        failures = []
        session.transferPasteboard(.send) { failures.append($0.localizedDescription) }
        try await wait { display.pasteboards.first?.transfers == [.send] }
        let current = display.pasteboards[0]
        abandoned(.activated)
        abandoned(.activated)
        abandoned(.lostConnection)
        #expect(!current.isDisconnected)
        #expect(failures.isEmpty)

        // The push is still this connection's to complete.
        current.send(.activated)
        current.send(.lostConnection)
        #expect(failures == ["Could not send the pasteboard to the simulator: The simulator closed its pasteboard connection."])
    }
}
