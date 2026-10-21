import ABIBridge
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
        for command in [DeviceCommand.ID.home, .lock, .toggleSoftwareKeyboard] {
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
        let commands = toolbar.items.filter { DeviceCommand.ID(rawValue: $0.itemIdentifier.rawValue) != nil }
        #expect(commands.filter { !$0.isHidden }.map(\.itemIdentifier.rawValue) ==
            ["home", "saveScreen", "rotateRight"])
        let home = try #require(commands.first { $0.itemIdentifier.rawValue == "home" })
        #expect(NSApp.sendAction(try #require(home.action), to: home.target, from: home))
        #expect(display.buttons == [.home])
        #expect(controller.session.reserve())
        await Task.yield()
        #expect(home.isEnabled)
        #expect(commands.filter { ["saveScreen", "rotateRight"].contains($0.itemIdentifier.rawValue) }
            .allSatisfy { !$0.isEnabled })
        controller.session.disconnect()
        await Task.yield()
        #expect(commands.allSatisfy { !$0.isEnabled })
    }

    @Test func toolbarShowsRecordingStopAndHidesItAfterCompletion() async throws {
        let controller = try makeController(TestDisplay()) { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", """
                trap 'exit 0' INT
                echo 'Recording started' >&2
                while :; do sleep 0.05; done
                """]
            return process
        }
        defer { controller.invalidate() }
        let toolbar = try #require(controller.window?.toolbar)
        let item = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "stopRecording" })
        #expect(item.isHidden)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try controller.session.startRecording(to: directory.appendingPathComponent("Recording.mp4"))
        let recording = try #require(controller.session.recording)
        for _ in 0..<100 where item.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!item.isHidden)
        #expect(item.isEnabled)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        for _ in 0..<100 where item.isEnabled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(recording.isStopping)
        #expect(!item.isEnabled)
        try await recording.waitUntilFinished()
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
            let frame = controller.session.display.view.frame
            #expect(frame.minX >= 0)
            #expect(frame.minY >= 0)
            #expect(frame.maxX <= content.bounds.maxX)
            #expect(frame.maxY <= window.contentLayoutRect.maxY - 12)
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
        #expect(!controller.session.canPerformCommands)
        #expect(!controller.session.canPerformToolOperation)
        #expect(display.buttons.isEmpty)
        controller.invalidate()
    }

    @Test func failedShutdownLeavesTheBootedDeviceUsable() async throws {
        let controller = try makeController(TestDisplay())
        defer { controller.invalidate() }
        var failure: Error?
        controller.session.run({ try await controller.session.shutDown() }, failure: { failure = $0 })
        for _ in 0..<3000 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(failure != nil)
        #expect(controller.session.canPerformCommands)
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

    @Test func editMenuLeavesEditingKeysToTheFocusedSimulator() throws {
        _ = NSApplication.shared
        MenuController(application: nil).install()
        defer { NSApp.mainMenu = nil }
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(window.firstResponder === display.inputView)
        let editing = try [("z", 6), ("x", 7), ("c", 8), ("v", 9)].map { key, code in
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: UInt16(code)))
        }
        for event in editing { NSApp.sendEvent(event) }
        #expect(display.input.keyDowns.map(\.keyCode) == [6, 7, 8, 9])
        window.makeFirstResponder(window)
        #expect(NSApp.mainMenu?.performKeyEquivalent(with: editing[3]) == true)
    }

    @Test func commandHeldKeyUpReachesTheNativeInputUntilTheWindowCloses() throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        let keyUp = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        NSApp.sendEvent(keyUp)
        #expect(display.input.keyUps.count == 1)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        NSApp.sendEvent(keyUp)
        #expect(display.input.keyUps.count == 1)
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
        let display = runtime.display
        let type = try #require(NSClassFromString("SimulatorKit.SimDisplayView") as? NSView.Type)
        let view = type.init(frame: .zero)
        #expect(object_getIvar(view, display.keyboardDelegate) == nil)
        let input = try unsafe display.digitizerView.unsafeInvoke(on: view)
        #expect(input.isDescendant(of: view))
        #expect(input.nextResponder === view)
        for _ in 0..<100 {
            #expect(try unsafe display.digitizerView.unsafeInvoke(on: view) === input)
        }
        let chrome = try unsafe display.chromeView.unsafeInvoke(on: view)
        let renderView = try #require(chrome.subviews.first {
            String(describing: Swift.type(of: $0)) == "SimDisplayChromeRenderView"
        })
        for active in [true, false, true] {
            let value = try display.chromeState.makeEnumCase(named: active ? "active" : "inactive")
            try unsafe display.setChromeState.unsafeInvoke(on: chrome, value)
            let state = try #require(Mirror(reflecting: renderView).children.first { $0.label == "state" })
            #expect(String(describing: state.value) == (active ? "active" : "inactive"))
        }
        try unsafe display.disconnect.unsafeInvoke(on: view, NativeSwiftClosure {})
    }

    @Test func unsupportedCommandsAreHiddenFromMenusAndToolbar() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let controller = try makeController(TestDisplay(), features: [])
        defer { controller.invalidate() }
        let toolbar = try #require(controller.window?.toolbar)
        #expect(toolbar.items.compactMap { DeviceCommand.ID(rawValue: $0.itemIdentifier.rawValue) } ==
            [.home, .saveScreen, .stopRecording])
        let device = try #require(NSApp.mainMenu?.items.first { $0.title == "Device" }?.submenu)
        menus.updateVisibility(in: device, for: controller.session.capabilities)
        let visible = device.items.filter { !$0.isHidden }
        #expect(visible.map { $0.isSeparatorItem ? "-" : $0.title } ==
            ["Shut Down", "-", "Home", "Lock", "Shake", "App Switcher", "-", "Trigger Screenshot"])
        controller.perform(.rotateRight)
        #expect(!controller.session.isBusy)
    }

    @Test func hardwareCommandsFollowDeviceFeatures() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let features: Set<String> = [
            DeviceCapabilities.actionButtonStaccato, DeviceCapabilities.siri,
            DeviceCapabilities.routableAudio, DeviceCapabilities.applePayAuthorization,
        ]
        let controller = try makeController(TestDisplay(), features: features)
        defer { controller.invalidate() }
        func visibleTitles(_ title: String) throws -> [String] {
            let menu = try #require(NSApp.mainMenu?.items.first { $0.title == title }?.submenu)
            menus.updateVisibility(in: menu, for: controller.session.capabilities)
            return menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title }
        }
        #expect(try visibleTitles("Device") == ["Shut Down", "-", "Home", "Lock", "Action Button", "Siri", "Shake",
                                                 "App Switcher", "-", "Trigger Screenshot"])
        #expect(try visibleTitles("I/O") == ["Keyboard", "-", "Increase Volume", "Decrease Volume", "-", "Open URL…"])
        #expect(try visibleTitles("Features") == ["Authorize Apple Pay", "-", "Toggle Appearance"])
    }

    @Test func hardwareCommandsSendSimulatorAppEvents() throws {
        let display = TestDisplay()
        let controller = try makeController(display, features: [
            DeviceCapabilities.siri, DeviceCapabilities.routableAudio, DeviceCapabilities.applePayAuthorization,
        ])
        defer { controller.invalidate() }
        for command in [DeviceCommand.ID.siri, .triggerScreenshot, .increaseVolume, .decreaseVolume, .authorizeApplePay] {
            controller.perform(command)
        }
        #expect(display.events.map(\.input) == [
            .button(.siri), .button(.siri), .screenshot, .screenshot, .volumeUp, .volumeUp,
            .volumeDown, .volumeDown, .button(.applePay), .button(.applePay),
        ])
        #expect(display.events.map(\.state) == Array(repeating: [HIDState.down, .up], count: 5).flatMap { $0 })
    }

    @Test func timedInputsKeepSimulatorAppDelays() async throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let clock = ContinuousClock()
        let start = clock.now
        controller.send(.pressTwice(.button(.home), interval: .milliseconds(150)))
        controller.send(.hold(.button(.actionStaccato), for: .milliseconds(500)))
        #expect(display.events.map(\.state) == [.down, .up, .down])
        while display.events.count < 6, clock.now - start < .seconds(5) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(clock.now - start >= .milliseconds(500))
        #expect(display.events.map(\.input) == [
            .button(.home), .button(.home), .button(.actionStaccato), .button(.home), .button(.home),
            .button(.actionStaccato),
        ])
        #expect(display.events.map(\.state) == [.down, .up, .down, .down, .up, .up])
    }

    @Test func closingTheWindowReleasesHeldInputsAndCancelsLaterSteps() async throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        controller.send(.hold(.button(.actionStaccato), for: .milliseconds(200)))
        controller.send(.pressTwice(.button(.home), interval: .milliseconds(200)))
        controller.invalidate()
        let sent = display.events.count
        #expect(display.events.last.map { $0.input == .button(.actionStaccato) && $0.state == .up } == true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(display.events.count == sent)
    }

    @Test func aFailedInputReportsOneError() throws {
        let display = TestDisplay()
        display.deliveryError = HostError.operation("delivery failed")
        let controller = try makeController(display)
        defer { controller.invalidate() }
        var failures: [Error] = []
        controller.session.send(.press(.button(.siri))) { failures.append($0) }
        #expect(display.events.count == 2)
        #expect(failures.count == 1)
    }

    private func makeController(_ display: TestDisplay,
                                features: Set<String> = [DeviceCapabilities.displayRotation],
                                recordingProcess: ((URL) -> Process)? = nil) throws -> DeviceWindowController {
        let session = DeviceSession(
            device: AvailableDevice(identifier: "test-device", name: "Test iPhone", runtimeName: "iOS", state: 3),
            capabilities: DeviceCapabilities(family: .iPhone, runtimeVersion: 0x1B_00_00,
                                             supportsFeature: { features.contains($0) }),
            display: display,
            tools: try DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app")),
            recordingProcess: recordingProcess)
        return try DeviceWindowController(session: session, onClose: { _ in })
    }
}

@MainActor
private final class InputView: NSView {
    var keyDowns: [NSEvent] = []
    var keyUps: [NSEvent] = []
    var modifiers: [NSEvent] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keyDowns.append(event) }
    override func keyUp(with event: NSEvent) { keyUps.append(event) }
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
    var events: [(input: HIDInput, state: HIDState)] = []
    /// Completes each sent event with this error.
    var deliveryError: Error?
    var buttons: [DeviceButton] {
        events.compactMap { if case .button(let button) = $0.input, $0.state == .down { button } else { nil } }
    }
    var activations: [Bool] = []
    var keyboard: [Bool] = []
    var disconnectCount = 0
    init() { view.addSubview(input) }
    func send(_ input: HIDInput, _ state: HIDState, completion: (@MainActor (Error?) -> Void)?) throws {
        events.append((input, state))
        completion?(deliveryError)
    }
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
    @Test func windowTitlesFollowSimulatorNaming() {
        #expect(deviceWindowTitles(name: "iPad Pro 11-inch (M5) (16GB)", runtimeName: "iOS 27.0")
            == ("iPad Pro 11-inch (M5)", "16GB – iOS 27.0"))
        #expect(deviceWindowTitles(name: "iPhone 17", runtimeName: "iOS 26.5") == ("iPhone 17", "iOS 26.5"))
        #expect(deviceWindowTitles(name: "My iPad (16GB)", runtimeName: "iOS 27.0") == ("My iPad (16GB)", "iOS 27.0"))
    }

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
