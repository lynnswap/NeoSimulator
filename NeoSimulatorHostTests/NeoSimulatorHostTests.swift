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
        controller.invalidate()
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(display.input.modifiers.count == 4)
        #expect(display.disconnectCount == 1)
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

    @Test func nativeDigitizerGetterKeepsIdentityAndResponderChain() throws {
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
        let input = try #require(XSHSwiftCallObjectGetter(runtime.digitizer, view) as? NSView)
        #expect(input.isDescendant(of: view))
        #expect(input.nextResponder === view)
        for _ in 0..<100 {
            #expect(XSHSwiftCallObjectGetter(runtime.digitizer, view) as? NSView === input)
        }
        XSHSwiftDisconnect(runtime.disconnect, view)
    }

    private func makeController(_ display: TestDisplay) throws -> DeviceWindowController {
        try DeviceWindowController(
            device: AvailableDevice(identifier: "test-device", name: "Test iPhone", runtimeName: "iOS", state: 3),
            display: display,
            tools: DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app")),
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
    var disconnectCount = 0
    init() { view.addSubview(input) }
    func press(_ button: DeviceButton) throws { buttons.append(button) }
    func shake() throws {}
    func toggleAppearance() throws {}
    func setChromeVisible(_ visible: Bool) {}
    func setRotation(degrees: Double) {}
    func beginResize() {}
    func resize(to size: NSSize) { view.setFrameSize(size) }
    func endResize() {}
    func disconnect() { disconnectCount += 1 }
}

@Suite @MainActor
struct HostBehaviorTests {
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
