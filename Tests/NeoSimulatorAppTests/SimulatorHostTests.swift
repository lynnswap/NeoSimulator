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

@Suite(.serialized) @MainActor
struct SimulatorHostTests {
    @MainActor final class RemoteTarget {
        weak var controller: DeviceWindowController?
    }

    func updateCanvas(_ operation: @MainActor () -> Void) {
        // Geometry assertions need immediate layout, independent of offscreen animation completion.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            operation()
        }
    }

    /// The display's rect in the canvas document, wherever the canvas presents the display.
    func documentRect(of view: NSView, in scroll: NSScrollView) -> NSRect {
        view.convert(view.bounds, to: scroll.documentView)
    }

    /// The canvas's fitting area in its document's coordinates.
    func fitRect(of content: NSView, in scroll: NSScrollView) throws -> NSRect {
        let viewport = try #require(content.layoutGuides.first { $0.identifier.rawValue == "DeviceCanvasViewport" })
        return content.convert(viewport.frame, to: scroll.documentView)
    }

    /// The device point, in unscaled display coordinates, under the center of the canvas's fitting area.
    func visibleDevicePoint(of view: NSView, in scroll: NSScrollView, fitting viewport: NSLayoutGuide,
                                    of content: NSView) -> NSPoint {
        let fit = content.convert(viewport.frame, to: scroll.documentView)
        let rect = documentRect(of: view, in: scroll)
        return NSPoint(x: fit.midX - rect.minX, y: fit.midY - rect.minY)
    }

    func center(of view: NSView, in content: NSView) -> NSPoint {
        let rect = view.convert(view.bounds, to: content)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    func joinedClient(in set: SimulatorDeviceSet, identifier: String) async throws -> SimulatorDevice {
        async let first = set.client(withIdentifier: identifier)
        async let joined = set.client(withIdentifier: identifier.lowercased())
        let device = try #require(try await first)
        #expect(try await joined === device)
        return device
    }

    /// Cancels the client's own connection. The stream finishes when its context and set are both released.
    func endConnection(of device: SimulatorDevice) throws -> AsyncStream<Never> {
        let (released, finished) = AsyncStream.makeStream(of: Never.self)
        let remaining = Mutex(2)
        try autoreleasepool {
            let nativeSet = try #require((device.object as? NSObject)?.value(forKey: "deviceSet") as? NSObject)
            let context = try #require(nativeSet.value(forKey: "serviceContext") as? NSObject)
            for object in [nativeSet, context] {
                unsafe objc_setAssociatedObject(object, UnsafeRawPointer(bitPattern: 0x467)!, ReleaseSentinel {
                    if remaining.withLock({ $0 -= 1; return $0 == 0 }) { finished.finish() }
                }, .OBJC_ASSOCIATION_RETAIN)
            }
            xpc_connection_cancel(try #require(context.value(forKey: "serviceConnection") as? xpc_connection_t))
        }
        return released
    }

    final class ReleaseSentinel: Sendable {
        let released: @Sendable () -> Void
        init(released: @escaping @Sendable () -> Void) { self.released = released }
        deinit { released() }
    }

    /// A headless in-process host showing a set this test owns, which reads list a device that only they know of. The
    /// host reads the default set and registers with this one, and it connects to no device and stops none.
    func makeHostWithListedTestingDevice() async throws -> (host: SimulatorScreenHost, device: SimulatorDeviceIdentifier,
                                                                    channel: SimulatorDeviceChannel, cleanUp: @MainActor () -> Void) {
        let runtime = try await makeRuntime()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        HostPreferences.defaults.set(directory.path, forKey: HostPreferences.testingDeviceSetPath)
        HostPreferences.defaults.set(true, forKey: HostPreferences.showTestingDevices)
        let cleanUp: @MainActor () -> Void = {
            HostPreferences.defaults.removeObject(forKey: HostPreferences.testingDeviceSetPath)
            HostPreferences.defaults.removeObject(forKey: HostPreferences.showTestingDevices)
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            let identifier = UUID().uuidString
            let set = runtime.io.openDeviceSet(at: directory.path, listing: [identifier])
            let host = try SimulatorScreenHost(runtime: runtime.io, conflicts: HostConflictMonitor(), headless: true, inProcess: true)
            try await host.start(attachingBootedDevices: false)
            #expect(host.isObservingTestingSet)
            return (host, SimulatorDeviceIdentifier(identifier, deviceSetPath: directory.path), set.channel, cleanUp)
        } catch {
            cleanUp()
            throw error
        }
    }

    func waitForStates(of channel: SimulatorDeviceChannel, _ states: [UnresolvedDeviceOperation.State]) async throws {
        for _ in 0..<1000 where await channel.unresolvedOperations().map(\.state) != states {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await channel.unresolvedOperations().map(\.state) == states)
    }

    static let microphone = HostAudioDevice(uid: "Microphone", name: "MacBook Pro Microphone",
                                                    inputChannels: 1, outputChannels: 0, defaultScopes: 1)

    static let speakers = HostAudioDevice(uid: "Speakers", name: "MacBook Pro Speakers",
                                                  inputChannels: 0, outputChannels: 2, defaultScopes: 2)

    static let loopback = HostAudioDevice(uid: "Loopback", name: "BlackHole 2ch",
                                                  inputChannels: 2, outputChannels: 2, defaultScopes: 0)

    static let headset = HostAudioDevice(uid: "Headset", name: "USB Headset",
                                                 inputChannels: 1, outputChannels: 2, defaultScopes: 0)

    static let routableFeatures = defaultFeatures.union([DeviceCapabilities.routableAudio])

    func makeAudioController(_ port: TestAudioRoutes?, device: String = "test-device",
                                     features: Set<String> = routableFeatures,
                                     preferences: MemoryPreferences) throws -> (DeviceWindowController, TestDisplay) {
        let display = TestDisplay()
        display.audioPort = port
        return (try makeController(display, features: features, device: device, preferences: preferences), display)
    }

    func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        return ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { texts(in: $0) }
    }

    static let externalDisplayFeatures = defaultFeatures.union(
        [DeviceCapabilities.externalDisplay, DeviceCapabilities.integratedDisplay])

    /// Connects the external display after the screen adapter reports it.
    func makeExternalDisplayController(_ screen: TestExternalScreen? = TestExternalScreen(),
                                               family: DeviceCapabilities.Family = .iPhone,
                                               features: Set<String> = Self.externalDisplayFeatures,
                                               device: String = "test-device",
                                               preferences: MemoryPreferences = MemoryPreferences(),
                                               externalDisplayChanges: ExternalDisplayChanges = ExternalDisplayChanges(),
                                               runtimeVersion: UInt32 = 0x1B_00_00,
                                               enhancedMultitasking: Bool = false,
                                               keyboardCaptureTap: any KeyboardEventTap = SystemKeyboardEventTap(),
                                               failure: @escaping @MainActor (Error) -> Void = { Issue.record($0) },
                                               applicationIsActive: @escaping () -> Bool = { NSApp.isActive },
                                               makeWindow: @escaping @MainActor (NSRect) -> NSWindow = ExternalDisplayWindowController.makeWindow)

        throws -> (DeviceWindowController, TestDisplay) {
        let display = TestDisplay()
        if let screen { display.connectExternalScreen(screen) }
        let controller = try makeController(display, family: family, features: features, device: device,
                                            preferences: preferences, externalDisplayChanges: externalDisplayChanges,
                                            runtimeVersion: runtimeVersion, enhancedMultitasking: enhancedMultitasking,
                                            keyboardCaptureTap: keyboardCaptureTap, applicationIsActive: applicationIsActive,
                                            makeExternalDisplayWindow: makeWindow)
        controller.session.connectExternalDisplay(failure: failure)
        display.deliverScreenReports()
        return (controller, display)
    }

    func externalDisplayItems(for controller: DeviceWindowController?) -> [String] {
        ExternalDisplayMode.allCases.map { mode in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let enabled = DeviceCommand.command(mode.commandID).validate(item, for: controller)
            return "\(item.title)\(item.state == .on ? " ✓" : "")\(enabled ? "" : " (disabled)")"
        }
    }

    /// A session with the external display `screen`, whose device stops answering during `whileHeld` and then answers
    /// again. It returns once the recovery changes finish, keeping the session alive for the caller's assertions.
    func recoverExternalDisplay(_ screen: TestExternalScreen, features: Set<String> = Self.externalDisplayFeatures,
                                        preferences: MemoryPreferences = MemoryPreferences(),
                                        whileHeld: (DeviceSession) async throws -> Void) async throws -> DeviceSession {
        let display = TestDisplay()
        display.connectExternalScreen(screen)
        let worker = HeldDeviceWorker(limit: .milliseconds(50))
        defer { worker.release() }
        let model = standaloneDeviceModel()
        model.follow(worker.channel)
        let changes = ExternalDisplayChanges()
        let session = try makeSession(display, features: features, model: model, preferences: preferences,
                                      externalDisplayChanges: changes)
        var recovered = false
        defer { if !recovered { session.disconnect() } }
        session.connectExternalDisplay { Issue.record($0) }
        display.deliverScreenReports()
        display.worker = worker
        screen.worker = worker
        worker.hold()
        await #expect(throws: DeviceOperationFailure.self) { try await worker.call("hold the device") }
        try await wait { model.unresponsiveOperation == "hold the device" }
        try await whileHeld(session)
        worker.release()
        try await wait { model.unresponsiveOperation == nil && worker.calls.contains("read the device's state") }
        // Recovery enqueues external-display work before reading command state.
        try #require(await changes.idle(before: .now + .seconds(2)))
        recovered = true
        return session
    }

    func externalDisplaySubtitles(for controller: DeviceWindowController) -> [String] {
        ExternalDisplayMode.allCases.compactMap { mode in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let enabled = DeviceCommand.command(mode.commandID).validate(item, for: controller)
            return item.subtitle.map { "\(item.title)\(enabled ? "" : " (disabled)"): \($0)" }
        }
    }

    /// A call that has nothing to do with the external display, whose own limit does not pass here, so that what is
    /// asked of the worker next waits behind it.
    func holdWithAnotherCall(_ worker: HeldDeviceWorker) async throws -> Task<Void, any Error> {
        worker.hold()
        let holding = Task { try await worker.call("another call") }
        try await wait { worker.calls == ["another call"] }
        return holding
    }

    /// Everything asked of the worker before this has run or been withdrawn when it returns.
    func finishCall(_ holding: Task<Void, any Error>, on worker: HeldDeviceWorker) async throws {
        worker.release()
        try await holding.value
        try await worker.call("last call")
    }

    static let carPlayFeatures = externalDisplayFeatures.union([DeviceCapabilities.carPlay])

    static let scenarios = [LocationScenario(name: "City Run", localizedName: "City Run"),
                                    LocationScenario(name: "Freeway Drive", localizedName: "Freeway Drive")]

    /// Clears location preferences and returns their restoration closure.
    func removeLocationPreferences() -> () -> Void {
        let keys = [HostPreferences.locationMode, HostPreferences.locationScenario,
                    HostPreferences.locationLatitude, HostPreferences.locationLongitude]
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        let shared = HostPreferences.deviceSettingsDefaults
        let presetKey = "DeviceLocationPreset.test-device"
        let savedPreset = shared?.object(forKey: presetKey)
        shared?.removeObject(forKey: presetKey)
        shared?.synchronize()
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        return {
            for key in keys { UserDefaults.standard.set(saved?[key], forKey: key) }
            shared?.set(savedPreset, forKey: presetKey)
            shared?.synchronize()
        }
    }

    enum Duo {
        static let phone = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
        static let duo = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
        static let watch = "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11"
        static let ios270 = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        static let ios271 = "com.apple.CoreSimulator.SimRuntime.iOS-27-1"
        static let ios272 = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
        static let ios272Duo = "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4"
        static let watchOS = "com.apple.CoreSimulator.SimRuntime.watchOS-27-2"

        /// Lists Duo first to show that CoreSimulator's order doesn't decide the default category.
        static func catalog() -> SimulatorCatalog {
            SimulatorCatalog(
                deviceTypes: [.init(identifier: duo, name: "iPhone Duo", productFamily: 1),
                              .init(identifier: phone, name: "iPhone 17", productFamily: 1),
                              .init(identifier: "pad", name: "iPad", productFamily: 2),
                              .init(identifier: watch, name: "Apple Watch Series 11", productFamily: 4)],
                runtimes: [.init(identifier: ios270, name: "iOS 27.0", buildVersion: "24A434"),
                           .init(identifier: ios271, name: "iOS 27.1", buildVersion: "24A94401"),
                           .init(identifier: ios272, name: "iOS 27.2", buildVersion: "24B114"),
                           .init(identifier: ios272Duo, name: "iOS 27.2", buildVersion: "24B91016s"),
                           .init(identifier: watchOS, name: "watchOS 27.2", buildVersion: "24R1")],
                supportedDeviceTypes: [ios270: [phone, "pad"], ios271: [duo], ios272: [phone, "pad"], ios272Duo: [duo],
                                       watchOS: [watch]],
                canPair: { _, _, _, _ in true })
        }
    }

    func pairingCatalog(_ pairings: PairingChecks? = nil) -> SimulatorCatalog {
        SimulatorCatalog(
            deviceTypes: [.init(identifier: "phone", name: "iPhone A", productFamily: 1),
                          .init(identifier: "incompatible-phone", name: "iPhone Incompatible", productFamily: 1),
                          .init(identifier: "pad", name: "iPad A", productFamily: 2),
                          .init(identifier: "w1", name: "Apple Watch One", productFamily: 4),
                          .init(identifier: "w2", name: "Apple Watch Two", productFamily: 4),
                          .init(identifier: "w3", name: "Apple Watch Old", productFamily: 4),
                          .init(identifier: "unavailable-watch", name: "Apple Watch Unavailable", productFamily: 4)],
            runtimes: [.init(identifier: "ios", name: "iOS 27.0"), .init(identifier: "old", name: "watchOS 10.0"),
                       .init(identifier: "new", name: "watchOS 27.0"), .init(identifier: "tv", name: "tvOS 27.0")],
            supportedDeviceTypes: ["ios": ["phone", "incompatible-phone", "pad"], "old": ["w3"], "new": ["w1", "w2"]],
            canPair: { watchType, watchRuntime, phoneType, phoneRuntime in
                pairings?.entries.append([watchType, watchRuntime, phoneType, phoneRuntime].joined(separator: " "))
                return watchType == "w1" && watchRuntime == "new" && phoneType == "phone" && phoneRuntime == "ios"
            })
    }

    func inputPlan(_ family: DeviceCapabilities.Family, _ features: Set<String>, plugin: Bool = false,
                           deviceType: String = "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                           defaultSet: Bool = true, runtimeVersion: UInt32 = 0x1B_00_00) -> NativeInputPlan {
        NativeInputPlan(capabilities: DeviceCapabilities(family: family, runtimeVersion: runtimeVersion,
                                                         supportsFeature: { features.contains($0) },
                                                         hasUserInterfacePlugin: plugin),
                        deviceTypeIdentifier: deviceType, isInDefaultSet: defaultSet)
    }

    @MainActor
    final class Counter {
        var value: Int
        init(_ value: Int = 0) { self.value = value }
    }

    /// One call that stays open until a test finishes it.
    @MainActor
    final class HeldCalls<Value> {
        private var held: CheckedContinuation<Value, any Error>?
        private(set) var calls = 0
        var isHolding: Bool { held != nil }
        func call() async throws -> Value {
            calls += 1
            return try await withCheckedThrowingContinuation { held = $0 }
        }
        func finish(_ result: Result<Value, any Error>) {
            let held = held
            self.held = nil
            // The waiting call shares this test's actor.
            nonisolated(unsafe) let result = result
            held?.resume(with: result)
        }
    }

    func isPending(_ readiness: SimulatorServiceReadiness) -> Bool { if case .pending = readiness { true } else { false } }

    func isReady(_ readiness: SimulatorServiceReadiness) -> Bool { if case .ready = readiness { true } else { false } }

    func isUnsupported(_ readiness: SimulatorServiceReadiness) -> Bool { if case .unsupported = readiness { true } else { false } }

    func isNotRouted(_ readiness: SimulatorServiceReadiness) -> Bool { if case .notRouted = readiness { true } else { false } }

    /// A simulator's CoreDevice record, which a test changes as CoreDevice does.
    @MainActor
    final class RecordFixture: CoreDeviceFeatureRecord {
        var connected = false
        var features: Set<String> = []
        var heldConnection: HeldCalls<Bool>?
        func isConnected() async throws -> Bool {
            if let heldConnection { return try await heldConnection.call() }
            return connected
        }
        func supports(_ feature: String) throws -> Bool { features.contains(feature) }
    }

    /// CoreDevice's list and notifications. Each stream starts with what is current, as CoreDevice's do.
    @MainActor
    final class RecordSourceFixture: CoreDeviceRecordSource {
        var current: RecordFixture?
        var readFailure: (any Error)?
        var heldReads: HeldCalls<RecordFixture?>?
        private(set) var reads = 0
        private(set) var recordFollows = 0
        private(set) var listNotifications = 0
        /// What each stream follows: a record, or CoreDevice's list for nil.
        private var streams: [Int: (record: RecordFixture?, continuation: AsyncThrowingStream<Void, any Error>.Continuation)] = [:]
        private var nextStream = 0
        var followers: Int { streams.count }
        func followers(of record: RecordFixture?) -> Int { streams.values.count { $0.record === record } }

        func record() async throws -> RecordFixture? {
            reads += 1
            if let heldReads { return try await heldReads.call() }
            if let readFailure { throw readFailure }
            return current
        }
        func followInventory(_ changed: @escaping @MainActor () -> Void) async throws { try await follow(nil, changed) }
        func follow(_ record: RecordFixture, _ changed: @escaping @MainActor () -> Void) async throws {
            recordFollows += 1
            try await follow(.some(record), changed)
        }
        func change() { for stream in streams.values { stream.continuation.yield() } }
        func change(of record: RecordFixture?) { for stream in streams.values where stream.record === record { stream.continuation.yield() } }
        func endStreams(throwing error: any Error) { for stream in streams.values { stream.continuation.finish(throwing: error) } }
        /// Changes CoreDevice's list, and returns once what follows the list has heard of it.
        func changeList(to record: RecordFixture?) async throws {
            current = record
            let heard = listNotifications
            change(of: nil)
            try await wait { listNotifications > heard }
        }

        private func follow(_ record: RecordFixture?, _ changed: @MainActor () -> Void) async throws {
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: Void.self)
            let number = nextStream
            nextStream += 1
            streams[number] = (record, continuation)
            defer { streams[number] = nil }
            continuation.yield()
            for try await _ in stream {
                changed()
                if record == nil { listNotifications += 1 }
            }
        }
    }

    /// Follows the key-window responder chain without making a test window key.
    func responder(in window: NSWindow, taking action: Selector) -> NSResponder? {
        window.firstResponder.flatMap { sequence(first: $0, next: \.nextResponder).first { $0.responds(to: action) } }
    }

    /// Loads the selected Xcode's private runtime.
    func makeRuntime() async throws -> SimulatorPresentationRuntime { try await loadTestRuntime() }

    func makeController(_ display: TestDisplay,
                                family: DeviceCapabilities.Family = .iPhone,
                                features: Set<String> = Self.defaultFeatures,
                                framebufferMask: Bool = false,
                                simctl: URL = URL(fileURLWithPath: "/usr/bin/false"),
                                devicectl: URL = URL(fileURLWithPath: "/usr/bin/false"),
                                recordingProcess: ((URL, DeviceTools.ScreenMask) -> Process)? = nil,
                                screenPointsPerInch: Double? = nil,
                                device identifier: String = "test-device",
                                preferences: MemoryPreferences = MemoryPreferences(),
                                touchPressure: TouchPressure? = nil,
                                tvRemote: TVRemoteController? = nil,
                                keyboardLanguage: @escaping @MainActor () -> String? = { "fr" },
                                openLog: @escaping (URL) async throws -> Void = { _ in },
                                pasteboard: NSPasteboard? = nil,
                                pasteboardSync: PasteboardSync? = nil,
                                externalDisplayChanges: ExternalDisplayChanges = ExternalDisplayChanges(),
                                userInterfacePlugin: Bool = false,
                                runtimeVersion: UInt32 = 0x1B_00_00,
                                enhancedMultitasking: Bool = false,
                                appResizeTransport: (@MainActor () async throws -> (any AppResizeTransport)?)? = nil,
                                userInterfacePluginLookUp: (attempts: Int, interval: Duration) = (5, .milliseconds(20)),
                                keyboardCaptureTap: any KeyboardEventTap = SystemKeyboardEventTap(),
                                applicationIsActive: @escaping () -> Bool = { NSApp.isActive },
                                makeExternalDisplayWindow: @escaping @MainActor (NSRect) -> NSWindow = ExternalDisplayWindowController.makeWindow,
                                performWindowDrag: @escaping (NSWindow, NSEvent) -> Void = { _, _ in },
                                presentCompactWindow: @escaping (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) },
                                onClose: @escaping (DeviceWindowController, DeviceLifetimeChoice?) -> Void = { _, _ in },
                                onRestart: @escaping (DeviceWindowController, Bool) -> Void = { _, _ in },
                                onShutDown: ((DeviceWindowController) -> Void)? = nil,
                                model: DeviceModel? = nil)

        throws -> DeviceWindowController {
        let session = try makeSession(display, family: family, features: features, framebufferMask: framebufferMask,
                                      simctl: simctl, devicectl: devicectl, recordingProcess: recordingProcess,
                                      openLog: openLog, screenPointsPerInch: screenPointsPerInch, device: identifier,
                                      model: model, preferences: preferences, keyboardLanguage: keyboardLanguage,
                                      pasteboard: pasteboard, pasteboardSync: pasteboardSync,
                                      externalDisplayChanges: externalDisplayChanges,
                                      userInterfacePlugin: userInterfacePlugin, runtimeVersion: runtimeVersion,
                                      enhancedMultitasking: enhancedMultitasking, appResizeTransport: appResizeTransport)
        return try DeviceWindowController(
            session: session, displays: testDisplays, preferences: preferences,
            touchPressure: touchPressure ?? TouchPressure(preferences: preferences, forceTouchTrackpad: { false }),
            tvRemote: tvRemote ?? TVRemoteController(target: { nil }),
            performWindowDrag: performWindowDrag, presentCompactWindow: presentCompactWindow,
            makeKeyboardCaptureTap: { keyboardCaptureTap }, applicationIsActive: applicationIsActive,
            makeExternalDisplayWindow: makeExternalDisplayWindow,
            userInterfacePluginLookUp: userInterfacePluginLookUp,
            onClose: onClose, onRestart: onRestart, onShutDown: onShutDown)
    }

    static let defaultFeatures: Set<String> = [DeviceCapabilities.displayRotation, DeviceCapabilities.keyboard]

    /// Acknowledges the first frame and exits normally on SIGINT.
    static func recorder(then script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap 'exit 0' INT; echo 'Recording started' >&2; \(script)"]
        return process
    }

    /// Simulator.app's threshold: nib button widths plus padding, title width, and 130 points.
    static func unifiedWidth(title: String = "Test iPhone", subtitle: String = "iOS") -> CGFloat {
        func width(_ text: String, _ style: NSFont.TextStyle) -> CGFloat {
            let font = NSFont.preferredFont(forTextStyle: style, options: [:])
            return NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        return (32 + 4) + (31 + 4) + (32 + 4) + (25 + 4) + max(width(title, .headline), width(subtitle, .subheadline)) + 130
    }

    /// Uses an iPhone-style bezel with no top padding.
    func makeBezelController(preferences: MemoryPreferences = MemoryPreferences(),
                                     performWindowDrag: @escaping (NSWindow, NSEvent) -> Void = { _, _ in })

        throws -> (DeviceWindowController, TestDisplay) {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 100, height: 200)
        display.bezel = NSSize(width: 20, height: 20)
        display.bezelPadding = NSSize(width: 9, height: 0)
        let controller = try makeController(display, preferences: preferences, performWindowDrag: performWindowDrag)
        controller.showWindow(nil)
        return (controller, display)
    }

    /// Returns the resize corner's center in screen coordinates.
    func point(of corner: DisplayResizeCorner, in display: TestDisplay) throws -> NSPoint {
        let bounds = display.view.bounds
        let point = NSPoint(x: corner.isLeft ? bounds.minX + 10 : bounds.maxX - 10,
                            y: corner.isLower ? bounds.minY + 10 : bounds.maxY - 10)
        let window = try #require(display.view.window)
        return window.convertPoint(toScreen: display.view.convert(point, to: nil))
    }

    /// Returns the left bezel's midpoint in window coordinates, away from resize corners.
    func pointOnBezel(of display: TestDisplay) throws -> NSPoint {
        let view = display.view
        try #require(view.window != nil)
        return view.convert(NSPoint(x: 5 * display.renderScale, y: view.bounds.midY), to: nil)
    }

    /// Hit-tests and dispatches through the responder chain as AppKit does.
    func press(_ window: NSWindow, at location: NSPoint) throws -> NSView {
        let hit = try #require(window.contentView?.superview?.hitTest(location))
        hit.mouseDown(with: try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)))
        return hit
    }

    /// Sends unhandled drag events directly to the window, as a bezel-corner drag does.
    func drag(_ window: NSWindow, from start: NSPoint, by offset: NSSize,
                      during: () throws -> Void = {}) throws {
        func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: window.convertPoint(fromScreen: location), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let end = NSPoint(x: start.x + offset.width, y: start.y + offset.height)
        window.mouseDown(with: try event(.leftMouseDown, at: start))
        window.mouseDragged(with: try event(.leftMouseDragged, at: end))
        try during()
        window.mouseUp(with: try event(.leftMouseUp, at: end))
    }

    func standaloneDeviceModel() -> DeviceModel {
        DeviceModel(inventory: .simulator(SimulatorHostDevice(identifier: "test-device", name: "Test iPhone", descriptiveName: "Test iPhone",
            runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted")), source: LiveDeviceStateSource())
    }

    func makeSession(_ display: TestDisplay,
                             family: DeviceCapabilities.Family = .iPhone,
                             features: Set<String> = Self.defaultFeatures,
                             framebufferMask: Bool = false,
                             simctl: URL = URL(fileURLWithPath: "/usr/bin/false"),
                             devicectl: URL = URL(fileURLWithPath: "/usr/bin/false"),
                             recordingProcess: ((URL, DeviceTools.ScreenMask) -> Process)? = nil,
                             recordings: RecordingStore = RecordingStore(),
                             openLog: @escaping (URL) async throws -> Void = { _ in },
                             screenPointsPerInch: Double? = nil,
                             device identifier: String = "test-device",
                             deviceSetPath: String? = nil,
                             model: DeviceModel? = nil,
                             preferences: MemoryPreferences = MemoryPreferences(),
                             keyboardLanguage: @escaping @MainActor () -> String? = { "fr" },
                             pasteboard: NSPasteboard? = nil,
                             pasteboardSync: PasteboardSync? = nil,
                             pasteboardTransport: (any PasteboardTransport)? = nil,
                             externalDisplayChanges: ExternalDisplayChanges = ExternalDisplayChanges(),
                             userInterfacePlugin: Bool = false,
                             runtimeVersion: UInt32 = 0x1B_00_00,
                             enhancedMultitasking: Bool = false,
                             appResizeTransport: (@MainActor () async throws -> (any AppResizeTransport)?)? = nil) throws -> DeviceSession {
        if let pasteboard { display.managedPasteboard = pasteboard }
        display.pasteboardTransport = pasteboardTransport
        // Keep the external-display timeout short enough to exercise expiry.
        return DeviceSession(
            device: availableDevice(identifier, "Test iPhone", runtime: "iOS", state: 3, deviceSetPath: deviceSetPath),
            capabilities: DeviceCapabilities(family: family, runtimeVersion: runtimeVersion,
                                             supportsFeature: { features.contains($0) },
                                             hasFramebufferMask: framebufferMask,
                                             screenPointsPerInch: screenPointsPerInch,
                                             hasUserInterfacePlugin: userInterfacePlugin,
                                             supportsEnhancedMultitasking: enhancedMultitasking),
            display: display,
            tools: try DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
                                   simctl: simctl, devicectl: devicectl),
            model: model, recordings: recordings, recordingProcess: recordingProcess, openLog: openLog, preferences: preferences,
            hostKeyboardLanguage: keyboardLanguage, pasteboardSync: pasteboardSync,
            externalDisplayChanges: externalDisplayChanges, externalScreenTimeout: .milliseconds(100),
            appResizeTransport: appResizeTransport)
    }
}
