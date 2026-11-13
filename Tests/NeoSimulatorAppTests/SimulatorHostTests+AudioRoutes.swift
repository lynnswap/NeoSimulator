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
    @Test func audioRouteChangesWhileAReadIsHeldNeedOneMoreReadNotAQueue() async throws {
        let display = TestDisplay()
        let port = TestAudioRoutes([])
        display.audioPort = port
        let worker = HeldDeviceWorker()
        defer { worker.release() }
        let session = try makeSession(display, features: [DeviceCapabilities.routableAudio])
        session.connectAudioRoutes { _ in }
        port.worker = worker
        worker.hold()
        for _ in 0..<20 { port.changed?(.selectedDevice) }
        try await wait { worker.calls.count == 1 }
        #expect(port.stateReads == 2)
        port.current.inputRoute = "latest"
        worker.release()
        try await wait { session.audioRoutes?.inputRoute == "latest" && worker.calls.count == 2 }
        #expect(port.stateReads == 3)
    }

    @Test func audioMenusAreAttachedForTheKeyDeviceThatRoutesAudio() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let io = try #require(NSApp.mainMenu?.items.first { $0.title == "I/O" }?.submenu)
        let items = try ["Audio Input", "Audio Output"].map { title in try #require(io.items.first { $0.title == title }) }
        // Matches Simulator.app's placement between Touch Pressure and volume commands.
        let titles = io.items.map { $0.isSeparatorItem ? "-" : $0.title }
        #expect(titles.prefix(7) == ["Keyboard", "Touch Pressure", "-", "Audio Input", "Audio Output",
                                     "Increase Volume", "Decrease Volume"])
        func attached(_ window: DeviceWindowController?) -> [String] {
            menus.updateAudioMenus(for: window)
            return items.map { "\($0.submenu?.title ?? "none")\($0.isEnabled ? "" : " (disabled)")" }
        }
        #expect(attached(nil) == ["none (disabled)", "none (disabled)"])
        let preferences = MemoryPreferences()
        let (routing, _) = try makeAudioController(TestAudioRoutes([Self.speakers]), preferences: preferences)
        defer { routing.invalidate() }
        #expect(attached(routing) == ["Audio Input", "Audio Output"])
        let (silent, _) = try makeAudioController(nil, device: "B", features: Self.defaultFeatures, preferences: preferences)
        defer { silent.invalidate() }
        #expect(attached(silent) == ["none (disabled)", "none (disabled)"])
        menus.updateVisibility(in: io, for: silent.session.capabilities)
        #expect(items.allSatisfy { !$0.isHidden })
        #expect(attached(routing) == ["Audio Input", "Audio Output"])
    }

    @Test func audioMenusListTheMacsDevicesAndCheckTheGuestsRoute() throws {
        _ = NSApplication.shared
        let preferences = MemoryPreferences()
        let port = TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers, Self.headset])
        let (controller, _) = try makeAudioController(port, preferences: preferences)
        defer { controller.invalidate() }
        let input = AudioRouteMenu(scope: .input), output = AudioRouteMenu(scope: .output)
        func items(_ audio: AudioRouteMenu, keyDevice: Bool = true) -> [String] {
            let menu = NSMenu()
            audio.update(menu, for: keyDevice ? controller : nil)
            #expect(!menu.items.contains { $0.isSeparatorItem })
            return menu.items.map { "\($0.title)\($0.state == .on ? " ✓" : "")\($0.isEnabled ? "" : " (disabled)")" }
        }
        #expect(items(output) == ["System"])
        controller.session.connectAudioRoutes { Issue.record($0) }
        // System uses the Mac's default; device ordering comes from the port.
        #expect(items(input) == ["System (MacBook Pro Microphone) ✓", "MacBook Pro Microphone", "BlackHole 2ch", "USB Headset"])
        #expect(items(output) == ["System (MacBook Pro Speakers) ✓", "BlackHole 2ch", "MacBook Pro Speakers", "USB Headset"])
        preferences.set(["Headset"], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        port.report { $0.outputRoute = "Headset" }
        #expect(items(output) == ["System (MacBook Pro Speakers)", "BlackHole 2ch", "MacBook Pro Speakers", "USB Headset ✓"])
        port.report(.availableDevices) { $0.defaultOutput = "Elsewhere" }
        #expect(items(output).first == "System")
        // SimulatorKit substitutes the Mac's default when the guest's route is missing.
        #expect(port.current.outputRoute == "Headset")
        var state = port.current
        state.outputRoute = "Gone"
        #expect(state.selectedDevice(in: .output) == Self.speakers)
        #expect(state.selectedDevice(in: .input) == Self.microphone)

        (controller.session.display as? TestDisplay)?.isBooted = false
        #expect(!items(input).contains { $0.hasSuffix("(disabled)") })
        #expect(items(input, keyDevice: false) == ["System (disabled)"])
    }

    @Test func aChosenAudioRouteIsSavedAndAppliedToEveryDeviceWindow() throws {
        let preferences = MemoryPreferences()
        let ports = [TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers]),
                     TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers])]
        let (a, _) = try makeAudioController(ports[0], device: "A", preferences: preferences)
        let (b, _) = try makeAudioController(ports[1], device: "B", preferences: preferences)
        let (silent, silentDisplay) = try makeAudioController(TestAudioRoutes([Self.loopback]), device: "C",
                                                              features: Self.defaultFeatures, preferences: preferences)
        defer { [a, b, silent].forEach { $0.invalidate() } }
        for controller in [a, b, silent] { controller.session.connectAudioRoutes { Issue.record($0) } }
        #expect(preferences.recentAudioRoutes(in: .output) == [AudioRouting.systemDefault])
        #expect(ports.allSatisfy { $0.requests.isEmpty })
        #expect(silentDisplay.audioConnections == 0)
        for identifier in ["A", "B"] {
            try preferences.saveAudioRoute("Speakers", forDevice: identifier, in: .output)
        }

        a.selectAudioRoute { $0.chooseAudioRoute("Loopback", in: .output) }
        #expect(preferences.values[HostPreferences.recentAudioOutputDeviceUIDs] as? [String]
            == ["Loopback", AudioRouting.systemDefault])
        #expect(ports.map(\.requests) == [["output Loopback"], ["output Loopback"]])
        #expect(ports.allSatisfy { $0.current.outputRoute == "Loopback" && $0.current.inputRoute == AudioRouting.systemDefault })
        for identifier in ["A", "B"] {
            #expect(try preferences.preferredAudioRoutes(forDevice: identifier, in: .output).first == "Loopback")
        }
        #expect(preferences.recentAudioRoutes(in: .input) == [AudioRouting.systemDefault])

        b.selectAudioRoute { $0.chooseAudioRoute("Gone", in: .output) }
        #expect(ports.map(\.requests) == [["output Loopback"], ["output Loopback"]])
        b.selectAudioRoute { $0.chooseAudioRoute(AudioRouting.systemDefault, in: .output) }
        #expect(ports.map(\.requests.last) == ["output \(AudioRouting.systemDefault)", "output \(AudioRouting.systemDefault)"])
        for identifier in ["A", "B"] {
            #expect(try preferences.preferredAudioRoutes(forDevice: identifier, in: .output).first == AudioRouting.systemDefault)
        }
        for route in ["Loopback", "One", "Two", "Three", "Gone"] { a.selectAudioRoute { $0.chooseAudioRoute(route, in: .input) } }
        #expect(preferences.recentAudioRoutes(in: .input) == ["Gone", "Three", "Two", "One", "Loopback"])
        #expect(preferences.recentAudioRoutes(in: .output) == [AudioRouting.systemDefault, "Gone", "Loopback"])
        // Simulator.app falls back to System for empty or foreign lists.
        for stored in [[] as [Any], [1, 2] as [Any], "Loopback" as Any] {
            preferences.set(stored, forKey: HostPreferences.recentAudioInputDeviceUIDs)
            #expect(preferences.recentAudioRoutes(in: .input) == [AudioRouting.systemDefault])
        }
    }

    @Test func connectingAndPortChangesRouteToTheMostRecentRouteTheMacHas() throws {
        let preferences = MemoryPreferences()
        preferences.set(["Headset", "Loopback", AudioRouting.systemDefault], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        let port = TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers])
        let (controller, _) = try makeAudioController(port, preferences: preferences)
        defer { controller.invalidate() }
        controller.session.connectAudioRoutes { Issue.record($0) }
        #expect(port.requests == ["output Loopback"])
        port.report(.availableDevices) { $0.devices.append(Self.headset) }
        #expect(port.requests.last == "output Headset")
        port.report(.availableDevices) { $0.devices.removeAll { $0 == Self.headset } }
        #expect(port.requests.last == "output Loopback")
        port.report { $0.outputRoute = "Speakers" }
        #expect(port.requests.last == "output Loopback" && port.requests.count == 3)
        #expect(port.current.outputRoute == "Speakers")
        #expect(controller.session.audioRoutes?.outputRoute == "Speakers")
        port.report(.availableDevices) { $0.defaultOutput = "Loopback" }
        #expect(port.requests.count == 4)
        // Without a usable recent route or system default, leave the guest's route unchanged.
        preferences.set([AudioRouting.systemDefault], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        port.report(.availableDevices) { $0.devices = [Self.microphone, Self.loopback] }
        #expect(port.requests.count == 4)
        port.report(.availableDevices) { $0.devices.append(Self.speakers) }
        #expect(port.requests.last == "output \(AudioRouting.systemDefault)")

        controller.invalidate()
        #expect(port.isDisconnected)
        let count = port.requests.count
        port.report { $0.outputRoute = "Speakers" }
        #expect(port.requests.count == count)
    }

    @Test func reconnectingAudioPreservesTheDeviceChoiceInsteadOfTheGlobalRecentRoute() throws {
        let preferences = MemoryPreferences()
        preferences.set(["Headset", AudioRouting.systemDefault], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        try preferences.saveAudioRoute("Loopback", forDevice: "A", in: .output)
        for _ in 0..<2 {
            let port = TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers, Self.headset])
            let (controller, _) = try makeAudioController(port, device: "A", preferences: preferences)
            controller.session.connectAudioRoutes { Issue.record($0) }
            #expect(port.current.outputRoute == "Loopback")
            port.report { $0.outputRoute = "Speakers" }
            #expect(port.requests == ["output Loopback"])
            #expect(controller.session.audioRoutes?.outputRoute == "Speakers")
            port.report(.availableDevices) { $0.devices.removeAll { $0 == Self.headset } }
            #expect(port.requests == ["output Loopback", "output Loopback"])
            controller.invalidate()
        }
    }

    @Test func audioRouteFailuresOfAChoiceArePresentedAndOthersLogged() throws {
        let preferences = MemoryPreferences()
        let port = TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers])
        let (controller, _) = try makeAudioController(port, preferences: preferences)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        // Unrequested device changes report errors through the session handler.
        preferences.set(["Loopback"], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        port.routeError = SimulatorError.operation("port failed")
        var automatic: [String] = []
        controller.session.connectAudioRoutes { automatic.append($0.localizedDescription) }
        #expect(automatic == ["Could not route the audio output of Test iPhone to BlackHole 2ch: port failed"])
        #expect(window.attachedSheet == nil)
        controller.selectAudioRoute { $0.chooseAudioRoute("Speakers", in: .output) }
        #expect(port.requests == ["output Loopback", "output Speakers"])
        let sheet = try #require(window.attachedSheet)
        window.endSheet(sheet)
        port.routeError = nil
        port.refusal = SimulatorError.operation("refused")
        controller.selectAudioRoute { $0.chooseAudioRoute("Loopback", in: .output) }
        window.endSheet(try #require(window.attachedSheet))

        let (unconnected, display) = try makeAudioController(nil, device: "B", preferences: MemoryPreferences())
        defer { unconnected.invalidate() }
        unconnected.showWindow(nil)
        var reasons: [String] = []
        unconnected.session.connectAudioRoutes { reasons.append($0.localizedDescription) }
        #expect(display.audioConnections == 1 && reasons == ["The device has no audio route port."])
        #expect(unconnected.window?.attachedSheet == nil)
        unconnected.selectAudioRoute { $0.chooseAudioRoute("Loopback", in: .input) }
        let unavailable = try #require(unconnected.window?.attachedSheet)
        #expect(texts(in: unavailable.contentView).contains(
            "Could not change the audio input of Test iPhone: The device has no audio route port."))
        unconnected.window?.endSheet(unavailable)
    }
}
