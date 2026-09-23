import AppKit
import Testing

@Suite(.serialized) @MainActor
struct InputFocusTests {
    @Test func commandsAndActivationRestoreTheNativeInputOwner() throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        let controller = try makeController(display)
        let window = try #require(controller.window)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(window.firstResponder === display.inputView)
        #expect(display.input.modifiers.count == 1)
        #expect(display.input.modifiers.last?.modifierFlags == NSEvent.modifierFlags)
        for command in [DeviceCommand.home, .lock, .keyboard] {
            window.makeFirstResponder(window)
            controller.perform(command)
            #expect(window.firstResponder === display.inputView)
        }
        #expect(display.buttons == [.home, .lock, .softwareKeyboard])
        #expect(display.input.modifiers.count == 4)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        #expect(display.activations == [true, false])
        controller.invalidate()
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(display.activations == [true, false])
        #expect(display.input.modifiers.count == 4)
        #expect(display.disconnectCount == 1)
    }

    @Test func nativeToolbarPreservesDeviceCommandsAndBusyState() async throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        #expect(window.title == "Test iPhone")
        #expect(window.subtitle == "iOS")
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let toolbar = try #require(window.toolbar)
        let commands = toolbar.items.filter { DeviceCommand(rawValue: $0.itemIdentifier.rawValue) != nil }
        #expect(commands.filter { !$0.isHidden }.map(\.itemIdentifier.rawValue) ==
            ["home", "screenshot", "rotateRight"])
        let home = try #require(commands.first { $0.itemIdentifier.rawValue == "home" })
        #expect(NSApp.sendAction(try #require(home.action), to: home.target, from: home))
        #expect(display.buttons == [.home])
        controller.toolbarState.isBusy = true
        await Task.yield()
        #expect(home.isEnabled)
        #expect(commands.filter { ["screenshot", "rotateRight"].contains($0.itemIdentifier.rawValue) }
            .allSatisfy { !$0.isEnabled })
        controller.toolbarState.isConnected = false
        await Task.yield()
        #expect(commands.allSatisfy { !$0.isEnabled })
    }

    @Test func toolbarShowsRecordingStopAndHidesItAfterCompletion() async throws {
        let controller = try makeController(TestDisplay())
        defer { controller.invalidate() }
        let toolbar = try #require(controller.window?.toolbar)
        let item = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "recording" })
        #expect(item.isHidden)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
            trap 'exit 0' INT
            echo 'Recording started' >&2
            while :; do sleep 0.05; done
            """]
        let recording = try VideoRecording(process: process, startupTimeout: .seconds(3))
        controller.toolbarState.recording = recording
        for _ in 0..<100 where item.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!item.isHidden)
        #expect(item.isEnabled)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        for _ in 0..<100 where item.isEnabled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(recording.isStopping)
        #expect(!item.isEnabled)
        try await recording.waitUntilFinished()
        controller.toolbarState.recording = nil
        for _ in 0..<100 where !item.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        #expect(item.isHidden)
    }

    @Test func displayStaysBelowTheNativeToolbarWhenResized() throws {
        let controller = try makeController(TestDisplay())
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        for size in [NSSize(width: 360, height: 780), NSSize(width: 800, height: 420)] {
            window.setContentSize(size)
            controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
            let content = try #require(window.contentView)
            #expect(controller.display.view.frame.minX >= 0)
            #expect(controller.display.view.frame.minY >= 0)
            #expect(controller.display.view.frame.maxX <= content.bounds.maxX)
            #expect(controller.display.view.frame.maxY <= window.contentLayoutRect.maxY - 12)
            #expect(try #require(window.standardWindowButton(.closeButton)).isHidden == false)
        }
    }

    @Test func deviceToolPathsAreValidatedBeforeOperations() throws {
        #expect(FileManager.default.isExecutableFile(atPath: DeviceTools.simctl.path))
        #expect(FileManager.default.isExecutableFile(atPath: DeviceTools.devicectl.path))
        _ = try DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"))
    }

    @Test func shutdownStatePreventsFurtherDeviceCommands() throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        display.isBooted = false
        controller.perform(.home)
        controller.perform(.lock)
        #expect(!controller.canPerformCommands)
        #expect(!controller.canPerformToolOperation)
        #expect(display.buttons.isEmpty)
        controller.invalidate()
    }

    @Test func refusedFocusDoesNotSendModifierEvents() throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        let refusing = RefusingResponder()
        controller.window?.makeFirstResponder(refusing)
        controller.focusInput()
        #expect(controller.window?.firstResponder === refusing)
        #expect(display.input.modifiers.isEmpty)
        controller.invalidate()
    }

    @Test func keyboardInputAndModifiersFollowTheKeyWindow() throws {
        _ = NSApplication.shared
        let first = TestDisplay()
        let second = TestDisplay()
        let a = try makeController(first)
        let b = try makeController(second)
        defer { a.invalidate(); b.invalidate() }
        var events: [(flags: NSEvent.ModifierFlags, keyboards: [[Bool]])] = []
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            events.append((event.modifierFlags, [first.keyboard, second.keyboard]))
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        let flags = NSEvent.modifierFlags
        a.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: a.window))
        a.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: a.window))
        b.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: b.window))
        #expect(first.keyboard == [true, false])
        #expect(second.keyboard == [true])
        #expect(events.map(\.flags) == [flags, [], flags])
        #expect(events.map(\.keyboards) == [[[true], []], [[true], []], [[true, false], [true]]])
        a.invalidate()
        a.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        a.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(first.keyboard == [true, false])
        #expect(events.count == 3)
    }

    @Test func nativeDisplayKeepsInputIdentityAndChromeActivation() throws {
        _ = NSApplication.shared
        let selection = Process()
        let output = Pipe()
        selection.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        selection.arguments = ["-p"]
        selection.standardOutput = output
        try selection.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        selection.waitUntilExit()
        let developerPath = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let xcode = URL(fileURLWithPath: developerPath).deletingLastPathComponent().deletingLastPathComponent()
        let runtime = try SimulatorRuntime(xcodeURL: xcode)
        let type = try #require(NSClassFromString("SimulatorKit.SimDisplayView") as? NSView.Type)
        let view = type.init(frame: .zero)
        #expect(object_getIvar(view, runtime.keyboardInput) == nil)
        let input = try #require(XSHSwiftCallObjectGetter(runtime.digitizer, view) as? NSView)
        #expect(input.isDescendant(of: view))
        #expect(input.nextResponder === view)
        for _ in 0..<100 {
            #expect(XSHSwiftCallObjectGetter(runtime.digitizer, view) as? NSView === input)
        }
        let chrome = try #require(XSHSwiftCallObjectGetter(runtime.chromeView, view) as? NSView)
        let renderView = try #require(chrome.subviews.first {
            String(describing: Swift.type(of: $0)) == "SimDisplayChromeRenderView"
        })
        for active in [true, false, true] {
            XSHSwiftSetChromeActive(runtime.chromeState, chrome, active)
            let state = try #require(Mirror(reflecting: renderView).children.first { $0.label == "state" })
            #expect(String(describing: state.value) == (active ? "active" : "inactive"))
        }
        XSHSwiftDisconnect(runtime.disconnect, view)
    }

    private func makeController(_ display: TestDisplay) throws -> DeviceWindowController {
        try DeviceWindowController(
            device: AvailableDevice(identifier: "test-device", name: "Test iPhone", runtimeName: "iOS", state: 3),
            display: display,
            tools: try DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app")),
            onClose: { _ in })
    }
}

@MainActor
private final class InputView: NSView {
    var modifiers: [NSEvent] = []
    override var acceptsFirstResponder: Bool { true }
    override func flagsChanged(with event: NSEvent) { modifiers.append(event) }
}
@MainActor
private final class RefusingResponder: NSResponder {
    override func resignFirstResponder() -> Bool { false }
}
@MainActor
private final class TestDisplay: SimulatorDisplay {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 844))
    let input = InputView()
    var inputView: NSView { input }
    var naturalSize: NSSize { NSSize(width: 390, height: 844) }
    var isBooted = true
    var buttons: [DeviceButton] = []
    var activations: [Bool] = []
    var keyboard: [Bool] = []
    var disconnectCount = 0
    init() { view.addSubview(input) }
    func press(_ button: DeviceButton) throws { buttons.append(button) }
    func shake() throws {}
    func toggleAppearance() throws {}
    func setChromeVisible(_ visible: Bool) {}
    func setActive(_ active: Bool) { activations.append(active) }
    func setKeyboardEnabled(_ enabled: Bool) { keyboard.append(enabled) }
    func setRotation(degrees: Double) {}
    func beginResize() {}
    func resize(to size: NSSize) { view.setFrameSize(size) }
    func endResize() {}
    func disconnect() { disconnectCount += 1 }
}

@Suite @MainActor
struct HostBehaviorTests {
    @Test func launchConflictIsRetainedBeforeDeferredTeardown() {
        let center = NotificationCenter()
        let monitor = HostConflictMonitor(notificationCenter: center)
        var teardownCalled = false
        monitor.onConflict = { teardownCalled = true }
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: FixtureRunningApplication()])

        #expect(monitor.conflictingHostName == "Device Hub")
        #expect(throws: HostError.self) { try monitor.check() }
        #expect(!teardownCalled)
    }

    @Test func launchConflictFromBackgroundThreadIsRetainedDuringStartup() throws {
        let center = NotificationCenter()
        let monitor = HostConflictMonitor(notificationCenter: center)
        let application = FixtureRunningApplication()
        let posted = DispatchSemaphore(value: 0)
        // Keep the posting thread independent of shared dispatch workers while
        // the main actor is deliberately unavailable, as during startup.
        Thread.detachNewThread {
            center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: application])
            posted.signal()
        }
        try #require(posted.wait(timeout: .now() + 3) == .success)

        #expect(monitor.conflictingHostName == "Device Hub")
        #expect(throws: HostError.self) { try monitor.check() }
    }

    @Test func browserReflectsCatalogChangesAndReportsBootErrors() async throws {
        let source = TestCatalog()
        let model = DeviceBrowserModel(source: source)
        let device = try #require(model.devices.first)
        await model.open(device)?.value
        #expect(source.opened == [device.id])
        #expect(model.devices.first?.isBooted == true)
        source.failure = HostError.operation("Boot failed")
        await model.open(device)?.value
        #expect(model.errorMessage == "Boot failed")
        #expect(model.opening.isEmpty)
        source.devices = []
        model.refresh()
        #expect(model.devices.isEmpty)
    }

    @Test func captureFailurePreservesExistingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("capture.png")
        let original = Data("original".utf8)
        try original.write(to: destination)
        await #expect(throws: (any Error).self) {
            try await CaptureFile.write(to: destination, extension: "png") { temporary in
                try Data("partial".utf8).write(to: temporary)
                throw HostError.operation("Capture failed")
            }
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["capture.png"])
    }

    @Test func neoInstallationDoesNotRequireSimulatorApplication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let xcode = directory.appendingPathComponent("Xcode.app")
        let contents = xcode.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Developer"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.dt.Xcode"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let options = try HostLaunchOptions(arguments: ["--xcode", xcode.path])
        try options.validateInstallation()
        #expect(!FileManager.default.fileExists(atPath: contents.appendingPathComponent("Developer/Applications/Simulator.app").path))
    }

    @Test func launchArgumentsRejectAmbiguousStartupRequests() {
        #expect(throws: (any Error).self) {
            try HostLaunchOptions(arguments: ["--xcode", "/Xcode.app", "--validate-runtime", "--startup-result", "/tmp/result"])
        }
        #expect(throws: (any Error).self) {
            try HostLaunchOptions(arguments: ["--xcode", "relative.app"])
        }
    }
}

@MainActor
private final class TestCatalog: DeviceBrowserSource {
    var devices = [AvailableDevice(identifier: "phone", name: "Phone", runtimeName: "iOS 27", state: 1)]
    var opened: [String] = []
    var failure: Error?
    func availableSimulatorDevices() -> [AvailableDevice] { devices }
    func openSimulator(withIdentifier identifier: String) async throws {
        if let failure { throw failure }
        opened.append(identifier)
        devices = devices.map { AvailableDevice(identifier: $0.id, name: $0.name, runtimeName: $0.runtimeName, state: 3) }
    }
}

@Suite @MainActor
struct DeviceToolTests {
    @Test func drainsOutputAndReportsToolFailures() async throws {
        let runner = DeviceToolRunner()
        let data = try await runner.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 10000 ]; do echo stdout; echo stderr >&2; i=$((i+1)); done"])
        #expect(data.count == 70_000)
        await #expect(throws: (any Error).self) {
            try await runner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo rejected >&2; exit 7"])
        }
        #expect(runner.process == nil)
    }

    @Test func timeoutAndCancellationReapTheChildProcess() async throws {
        let runner = DeviceToolRunner()
        await #expect(throws: (any Error).self) {
            try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: .milliseconds(30))
        }
        #expect(runner.process == nil)
        let task = Task { try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]) }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(runner.process == nil)
    }
}

// The fixture adds no mutable state to NSRunningApplication's Sendable contract.
private final class FixtureRunningApplication: NSRunningApplication, @unchecked Sendable {
    override var bundleIdentifier: String? { "com.apple.dt.Devices" }
}
