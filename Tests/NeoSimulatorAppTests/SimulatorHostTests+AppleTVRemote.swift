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
    @Test func remoteWindowCoalescesLayoutSizesWithoutBlockingHID() async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let resize = TestAppResizeTransport()
        let primary = TestRemoteScreenTransport(), dedicated = TestRemoteScreenTransport()
        let session = RemoteDeviceScreenSession(device: device, makeResizeTransport: { _ in resize }) { _, _, target in
            target == nil ? primary : dedicated
        }
        let controller = RemoteDeviceWindowController(device: device, session: session, presentCompactWindow: { _ in })
        let window = try #require(controller.window)
        try await session.start()
        try await wait { session.canResizeApp }
        resize.lease.holdsAdjustment = true
        defer { resize.lease.completeAdjustment() }
        try await session.startAppResize(size: CGSize(width: 400, height: 600))
        window.setContentSize(CGSize(width: 500, height: 600))
        controller.presentationViewController.view.layoutSubtreeIfNeeded()
        controller.layoutScreen()
        try await wait { resize.lease.adjustmentContinuation != nil }
        let first = try #require(resize.lease.adjustedSizes.first)
        for size in [CGSize(width: 530, height: 650), CGSize(width: 570, height: 680), CGSize(width: 610, height: 720)] {
            window.setContentSize(size)
            controller.presentationViewController.view.layoutSubtreeIfNeeded()
            controller.layoutScreen()
        }
        let latest = try #require(session.contentView.superview?.bounds.size)
        controller.performScreenAction("home")
        do { try await wait { dedicated.buttons == [.down, .up] } }
        catch { Issue.record(error) }
        #expect(dedicated.buttons == [.down, .up], "An in-flight geometry adjustment blocked accepted HID input")
        resize.lease.holdsAdjustment = false
        resize.lease.completeAdjustment()
        try await wait { resize.lease.adjustedSizes.last == latest && dedicated.buttons == [.down, .up] }
        #expect(resize.lease.adjustedSizes == [first, latest])
        resize.lease.holdsAdjustment = true
        window.setContentSize(CGSize(width: 620, height: 730))
        controller.presentationViewController.view.layoutSubtreeIfNeeded()
        controller.layoutScreen()
        try await wait { resize.lease.adjustmentContinuation != nil }
        let accepted = resize.lease.adjustedSizes
        window.setContentSize(CGSize(width: 640, height: 750))
        controller.presentationViewController.view.layoutSubtreeIfNeeded()
        controller.layoutScreen()
        controller.performScreenAction("resizeApp")
        try await wait { session.isChangingDisplay }
        #expect(session.isResizingApp && resize.lease.invalidations == 0)
        resize.lease.holdsAdjustment = false
        resize.lease.completeAdjustment()
        try await wait { !session.isChangingDisplay && !session.isResizingApp }
        #expect(resize.lease.adjustedSizes == accepted && resize.lease.invalidations == 1)
        try await controller.stopAndClose()
    }

    @Test(arguments: [false, true]) func theAppleTVRemoteItemShowsAndHidesTheRemoteAsInSimulatorApp(integrated: Bool) throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        let windowMenu: NSMenu
        if integrated {
            windowMenu = NSMenu(title: "View")
            menus.addScreenCommands(file: NSMenu(), edit: NSMenu(), view: windowMenu)
        } else {
            menus.install()
            windowMenu = try #require(NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu)
        }
        defer { NSApp.mainMenu = nil }
        let item = try #require(windowMenu.items.first { $0.title == "Show Apple TV Remote" })
        // Matches Simulator.app's MainMenu.nib placement and shortcut.
        let index = windowMenu.index(of: item)
        #expect(windowMenu.items[index - 1].title == "Show Device Bezels")
        #expect(windowMenu.items[index + 1].title == "Stay On Top")
        let fullScreen = try #require(windowMenu.items.first { $0.title == "Enter Full Screen" })
        #expect(fullScreen.keyEquivalent == "f" && fullScreen.keyEquivalentModifierMask == [.command, .control])
        #expect(item.keyEquivalent == "r" && item.keyEquivalentModifierMask == [.command, .shift])
        for family in [DeviceCapabilities.Family.iPhone, .iPad, .tv, .watch, .vision] {
            menus.updateVisibility(in: windowMenu, for: DeviceCapabilities(family: family, runtimeVersion: 0x1B_00_00,
                                                                           supportsFeature: { _ in false }))
            #expect(!item.isHidden)
        }
        let remote = TVRemoteController(target: { nil })
        let tv = try makeController(TestDisplay(), family: .tv, features: [DeviceCapabilities.tvRemote], tvRemote: remote)
        let phone = try makeController(TestDisplay(), tvRemote: remote)
        defer {
            tv.invalidate()
            phone.invalidate()
            remote.close()
        }
        let command = DeviceCommand.command(.appleTVRemote)
        #expect(!command.validate(item, for: phone))
        #expect(command.validate(item, for: tv))
        #expect(item.title == "Show Apple TV Remote")
        tv.perform(.appleTVRemote)
        #expect(remote.isVisible)
        #expect(command.validate(item, for: tv))
        #expect(item.title == "Hide Apple TV Remote")
        tv.perform(.appleTVRemote)
        #expect(!remote.isVisible)
        #expect(command.validate(item, for: tv))
        #expect(item.title == "Show Apple TV Remote")
        // AppleRemotePanel leaves keyboard focus in the device window.
        #expect(remote.window?.canBecomeKey == false)
    }

    @Test func theRemotesButtonsHoldTheAppleTVsButtonsAsInSimulatorApp() throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        let target = RemoteTarget()
        let remote = TVRemoteController(target: { target.controller })
        let tv = try makeController(display, family: .tv, features: [DeviceCapabilities.tvRemote], tvRemote: remote)
        let phoneDisplay = TestDisplay()
        let phone = try makeController(phoneDisplay, tvRemote: remote)
        defer {
            tv.invalidate()
            phone.invalidate()
            remote.close()
        }
        target.controller = tv
        remote.showWindow(nil)
        let content = try #require(remote.window?.contentView)
        func view(_ label: String) throws -> NSView {
            try #require(content.subviews.first { $0.accessibilityLabel() == label }, "\(label)")
        }
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: remote.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let buttons: [(String, TVRemoteButton)] = [
            ("Select", .select), ("Menu", .menu), ("TV", .tv), ("Siri", .siri), ("Play/Pause", .playPause),
            ("Volume Up", .volumeUp), ("Volume Down", .volumeDown),
        ]
        for (label, button) in buttons {
            let view = try view(label)
            view.mouseDown(with: click)
            #expect(display.events.last?.input == .tvRemote(button) && display.events.last?.state == .down, "\(label)")
            view.mouseUp(with: click)
            #expect(display.events.last?.input == .tvRemote(button) && display.events.last?.state == .up, "\(label)")
        }
        #expect(display.events.count == 14)
        target.controller = phone
        try view("Menu").mouseDown(with: click)
        try view("Menu").mouseUp(with: click)
        #expect(phoneDisplay.events.isEmpty)
        target.controller = tv
        try view("Siri").mouseDown(with: click)
        remote.close()
        #expect(display.events.suffix(2).map(\.input) == [.tvRemote(.siri), .tvRemote(.siri)])
        #expect(display.events.suffix(2).map(\.state) == [.down, .up])
        remote.showWindow(nil)
        try view("Play/Pause").mouseDown(with: click)
        tv.session.disconnect()
        try view("Play/Pause").mouseUp(with: click)
        #expect(display.events.suffix(2).map(\.input) == [.tvRemote(.playPause), .tvRemote(.playPause)])
        #expect(display.events.suffix(2).map(\.state) == [.down, .up])
        #expect(display.events.count == 18)
    }

    @Test func closingTheRemoteSendsAgainWhatAnotherAppleTVStillHolds() throws {
        _ = NSApplication.shared
        let first = TestDisplay(), second = TestDisplay()
        let target = RemoteTarget()
        let remote = TVRemoteController(target: { target.controller })
        let a = try makeController(first, family: .tv, features: [DeviceCapabilities.tvRemote], device: "a", tvRemote: remote)
        let b = try makeController(second, family: .tv, features: [DeviceCapabilities.tvRemote], device: "b", tvRemote: remote)
        defer {
            a.invalidate()
            b.invalidate()
            remote.close()
        }
        remote.showWindow(nil)
        let window = try #require(remote.window)
        let content = try #require(window.contentView)
        let surface = try #require(content.subviews.compactMap { $0 as? TVRemoteTouchSurface }.first)
        let menu = try #require(content.subviews.first { $0.accessibilityLabel() == "Menu" })
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            let location = surface.convert(NSPoint(x: x * surface.bounds.width, y: (1 - y) * surface.bounds.height), to: nil)
            if type == .mouseEntered {
                return try #require(NSEvent.enterExitEvent(
                    with: type, location: location, modifierFlags: .option, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            }
            return try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func touch(_ phase: TVRemoteTouch.Phase, _ x: CGFloat, _ y: CGFloat) -> TVRemoteTouch {
            TVRemoteTouch(phase: phase, point: CGPoint(x: x, y: y))
        }
        // Switching targets leaves A's failed touch-end pending while B receives input.
        target.controller = a
        surface.mouseEntered(with: try event(.mouseEntered, 0.5, 0.5))
        first.undeliveredTouches = 1
        target.controller = b
        surface.mouseMoved(with: try event(.mouseMoved, 0.5, 0.75))
        remote.close()
        #expect(first.remoteTouches == [touch(.began, 0.5, 0.5), touch(.ended, 0.5, 0.75), touch(.ended, 0.5, 0.75)])
        #expect(second.remoteTouches == [touch(.began, 0.5, 0.75), touch(.ended, 0.5, 0.75)])
        // Both devices may hold Menu when A's release fails before switching to B.
        remote.showWindow(nil)
        target.controller = a
        first.undeliveredEvents = [1]
        menu.mouseDown(with: try event(.leftMouseDown, 0, 0))
        menu.mouseUp(with: try event(.leftMouseUp, 0, 0))
        target.controller = b
        menu.mouseDown(with: try event(.leftMouseDown, 0, 0))
        remote.close()
        #expect(first.events.map(\.state) == [.down, .up, .up])
        #expect(second.events.map(\.state) == [.down, .up])
        #expect((first.events + second.events).allSatisfy { $0.input == .tvRemote(.menu) })
    }

    @Test func aRemoteButtonOrTouchReportsOneErrorEach() throws {
        let display = TestDisplay()
        display.deliveryError = SimulatorError.operation("delivery failed")
        let controller = try makeController(display, family: .tv, features: [DeviceCapabilities.tvRemote])
        defer { controller.invalidate() }
        var failures = 0
        controller.session.pressRemoteButton(.menu) { _ in failures += 1 }
        controller.session.releaseRemoteButton(.menu)
        #expect(display.events.count == 2 && failures == 1)
        for point in [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5)] {
            controller.session.touchRemote(at: point) { _ in failures += 1 }
        }
        controller.session.liftRemoteTouch(at: CGPoint(x: 0.5, y: 0.5))
        #expect(display.remoteTouches.map(\.phase) == [.began, .moved, .ended] && failures == 2)
    }

    @Test func theRemoteClosesForAnotherDeviceAndWithTheLastAppleTVAsInSimulatorApp() throws {
        _ = NSApplication.shared
        let remote = TVRemoteController(target: { nil })
        func make(_ family: DeviceCapabilities.Family, _ features: Set<String>) throws -> DeviceWindowController {
            let controller = try makeController(TestDisplay(), family: family, features: features, tvRemote: remote)
            controller.showWindow(nil)
            return controller
        }
        func becomeKey(_ controller: DeviceWindowController) {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: controller.window)
        }
        let tv = try make(.tv, [DeviceCapabilities.tvRemote])
        let phone = try make(.iPhone, [])
        defer {
            tv.invalidate()
            phone.invalidate()
            remote.close()
        }
        remote.showWindow(nil)
        becomeKey(tv)
        #expect(remote.isVisible)
        becomeKey(phone)
        #expect(!remote.isVisible)
        remote.showWindow(nil)
        tv.window?.close()
        #expect(remote.isVisible)
        let lastTV = try make(.tv, [DeviceCapabilities.tvRemote])
        defer { lastTV.invalidate() }
        phone.window?.close()
        #expect(remote.isVisible)
        try #require(!NSApp.windows.contains { $0 !== lastTV.window && $0.isVisible && $0.windowController is DeviceWindowController })
        lastTV.window?.close()
        #expect(!remote.isVisible)
        let shutDown = try make(.tv, [DeviceCapabilities.tvRemote])
        remote.showWindow(nil)
        shutDown.invalidate()
        #expect(!remote.isVisible)
    }

    @Test func graphicsQualityAppliesAtOnceUnlessAnAppleTVRestartsItsSystemUI() async throws {
        let key = HostPreferences.graphicsQualityOverride
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("arguments"), simctl = directory.appendingPathComponent("simctl")
        try """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(log.path)"
            """.write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let quality = "com.apple.UIKit.ForceGraphicsQuality"
        for family in [DeviceCapabilities.Family.tv, .iPhone] {
            let display = TestDisplay()
            let controller = try makeController(display, family: family,
                                                features: [DeviceCapabilities.graphicsQualityOverride], simctl: simctl)
            defer { controller.invalidate() }
            // Device-tool work delays only the Apple TV restart, matching Simulator.app.
            #expect(controller.session.reserve())
            #expect(!DeviceCommand.command(.graphicsQualityHigh).isEnabled(controller))
            controller.perform(.graphicsQualityHigh)
            #expect(display.notificationStates[quality] == nil)
            controller.session.release()
            controller.perform(.graphicsQualityHigh)
            for _ in 0..<200 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
            #expect(display.notificationStates[quality] == 100)
        }
        #expect(try String(contentsOf: log, encoding: .utf8) == "spawn test-device launchctl stop com.apple.PineBoard\n")
    }
}
