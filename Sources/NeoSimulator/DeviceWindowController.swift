import AppKit
import UniformTypeIdentifiers

@MainActor
final class DeviceWindowController: NSWindowController, NSWindowDelegate {
    let device: AvailableDevice
    let display: any SimulatorDisplay
    let tools: DeviceTools
    let toolbarState = DeviceToolbarState()
    private(set) var showsDeviceBezel = true
    private var operation: Task<Void, Never>?
    private let recordings: RecordingStore
    private var closed = false
    private var didReadOrientation = false
    private let onClose: (String) -> Void
    private let content: DeviceContentView
    private var deviceToolbar: DeviceToolbar?
    var canPerformCommands: Bool { !closed && toolbarState.isConnected && display.isBooted }
    var canPerformToolOperation: Bool { canPerformCommands && !toolbarState.isBusy }
    var staysOnTop: Bool { window?.level == .floating }

    init(device: AvailableDevice, display: any SimulatorDisplay, tools: DeviceTools,
         recordings: RecordingStore = RecordingStore(), onClose: @escaping (String) -> Void) throws {
        self.device = device
        self.display = display
        self.tools = tools
        self.recordings = recordings
        self.onClose = onClose
        content = DeviceContentView(display: display.view)
        let natural = display.naturalSize
        guard natural.width > 0, natural.height > 0 else {
            display.disconnect()
            throw HostError.unavailable("Simulator display has no usable size")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.title = device.name
        window.subtitle = device.runtimeName
        window.appearance = NSAppearance(named: .darkAqua)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        let toolbar = DeviceToolbar(state: toolbarState) { [weak self] in self?.perform($0) }
        deviceToolbar = toolbar
        window.toolbar = toolbar.toolbar
        content.canImport = { [weak self] in self?.canPerformToolOperation == true }
        content.importFiles = { [weak self] in self?.importFiles($0) }
        window.contentView = content
        window.contentMinSize = NSSize(width: 320, height: 300)
        fitScreen()
    }

    required init?(coder: NSCoder) { nil }

    func showAndActivate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if !didReadOrientation {
            didReadOrientation = true
            runTool(presentError: false) { [self] in
                let angle = try await tools.orientation()
                try Task.checkCancellation()
                applyRotation(angle)
            }
        }
    }

    func perform(_ command: DeviceCommand) {
        guard canPerformCommands else { return }
        do {
            switch command {
            case .home: try display.press(.home)
            case .lock: try display.press(.lock)
            case .keyboard: try display.press(.softwareKeyboard)
            case .shake: try display.shake()
            case .appearance: try display.toggleAppearance()
            case .bezel:
                showsDeviceBezel.toggle()
                display.setChromeVisible(showsDeviceBezel)
                resizeDisplay()
            case .stayOnTop: window?.level = staysOnTop ? .normal : .floating
            case .fit: fitScreen()
            case .screenshot: saveScreenshot()
            case .rotateLeft, .rotateRight:
                runTool { [self] in
                    let angle = try await tools.rotate(left: command == .rotateLeft)
                    try Task.checkCancellation()
                    applyRotation(angle)
                }
            case .shutdown:
                guard canPerformToolOperation, toolbarState.recording == nil else { return }
                runTool { [self] in try await tools.shutdown() }
                toolbarState.isConnected = false
            case .recording: toggleRecording()
            case .importFiles: chooseFiles()
            case .openURL: openURL()
            }
        } catch { present(error) }
        focusInput()
    }

    private func runTool(presentError: Bool = true, _ action: @escaping @MainActor () async throws -> Void) {
        guard canPerformToolOperation else { return }
        toolbarState.isBusy = true
        operation = Task { [weak self] in
            defer {
                if let self {
                    self.toolbarState.isBusy = false
                    self.toolbarState.isConnected = !self.closed && self.display.isBooted
                    self.operation = nil
                }
            }
            do { try await action() }
            catch is CancellationError {}
            catch {
                if presentError { self?.present(error) }
                else { hostLog(error.localizedDescription) }
            }
        }
    }

    private func saveScreenshot() {
        guard canPerformToolOperation, let window else { return }
        toolbarState.isBusy = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Simulator Screenshot.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.toolbarState.isBusy = false
            guard response == .OK, let destination = panel.url, !self.closed else { return }
            self.runTool { [self] in
                try await CaptureFile.write(to: destination, extension: "png") { temporary in
                    try await tools.screenshot(to: temporary)
                    let handle = try FileHandle(forReadingFrom: temporary)
                    defer { try? handle.close() }
                    guard try handle.read(upToCount: 8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
                        throw HostError.operation("The screenshot tool did not produce a PNG file")
                    }
                }
            }
        }
    }

    private func toggleRecording() {
        if let recording = toolbarState.recording { recording.stop(); return }
        guard canPerformToolOperation, let window else { return }
        toolbarState.isBusy = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Simulator Recording.mp4"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.toolbarState.isBusy = false
            guard response == .OK, let destination = panel.url, !self.closed else { return }
            do {
                self.toolbarState.recording = try self.recordings.start(to: destination,
                    process: self.tools.recordingProcess) { [weak self] in
                        self?.toolbarState.recording = nil
                    }
            } catch { self.present(error) }
        }
    }

    private func chooseFiles() {
        guard canPerformToolOperation, let window else { return }
        toolbarState.isBusy = true
        let panel = NSOpenPanel()
        panel.title = "Install App or Import Media"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.applicationBundle, .image, .movie, .vCard]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.toolbarState.isBusy = false
            if response == .OK, !self.closed { self.importFiles(panel.urls) }
        }
    }

    private func importFiles(_ urls: [URL]) {
        runTool { [self] in
            try await SimulatorFileImport.perform(urls) { url, kind in
                switch kind {
                case .application: try await tools.installApplication(at: url)
                case .media: try await tools.importMedia(at: url)
                }
            }
        }
    }

    private func openURL() {
        guard canPerformToolOperation, let window else { return }
        toolbarState.isBusy = true
        let alert = NSAlert()
        alert.messageText = "Open URL in Simulator"
        alert.informativeText = "Enter a web address or an app's URL scheme."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://example.com"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.toolbarState.isBusy = false
            guard response == .alertFirstButtonReturn, !self.closed else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text), url.scheme != nil else {
                self.present(HostError.operation("Enter a URL with a scheme, such as https://example.com"))
                return
            }
            self.runTool { [self] in try await tools.openURL(url) }
        }
    }

    private func applyRotation(_ angle: Double) {
        display.setRotation(degrees: angle)
        fitScreen()
        resizeDisplay()
    }

    func fitScreen() {
        guard let window, !window.inLiveResize, !window.styleMask.contains(.fullScreen) else { return }
        let natural = display.naturalSize
        guard natural.width > 0, natural.height > 0 else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let scale = min(1, (visible.width - 20) / natural.width,
                        (visible.height - 20 - content.headerHeight - DeviceContentView.displayGap) / natural.height)
        window.setContentSize(NSSize(width: max(320, natural.width * scale),
            height: natural.height * scale + content.headerHeight + DeviceContentView.displayGap))
        resizeDisplay()
    }

    private func resizeDisplay() {
        guard !closed else { return }
        display.resize(to: content.availableDisplaySize)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        window?.invalidateShadow()
    }

    func focusInput() {
        guard canPerformCommands, let window else { return }
        window.makeFirstResponder(display.inputView)
        guard window.firstResponder === display.inputView else {
            hostLog("Could not focus simulator input for \(device.id)")
            return
        }
        // Reconcile modifier releases received while another window owned focus.
        if let event = NSEvent.keyEvent(with: .flagsChanged, location: window.mouseLocationOutsideOfEventStream,
            modifierFlags: NSEvent.modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0) {
            display.inputView.flagsChanged(with: event)
        }
    }

    func present(_ error: Error) {
        guard !closed, let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !closed else { return }
        display.setActive(true)
        focusInput()
    }
    func windowDidResignKey(_ notification: Notification) {
        if !closed { display.setActive(false) }
    }
    func windowWillStartLiveResize(_ notification: Notification) { if !closed { display.beginResize() } }
    func windowDidResize(_ notification: Notification) { resizeDisplay() }
    func windowDidEndLiveResize(_ notification: Notification) {
        if !closed { resizeDisplay(); display.endResize() }
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        disconnect()
        onClose(device.id)
    }
    func invalidate() {
        disconnect()
        window?.delegate = nil
        window?.close()
    }
    private func disconnect() {
        guard !closed else { return }
        closed = true
        toolbarState.isConnected = false
        operation?.cancel()
        tools.cancel()
        toolbarState.recording?.stop()
        if let window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
        }
        display.disconnect()
    }
    isolated deinit { disconnect() }
}

@MainActor
private final class DeviceContentView: NSView {
    static let displayGap: CGFloat = 12
    let display: NSView
    var canImport: () -> Bool = { false }
    var importFiles: ([URL]) -> Void = { _ in }
    var headerHeight: CGFloat {
        guard let window else { return 52 }
        return max(0, bounds.height - window.contentLayoutRect.height)
    }
    init(display: NSView) {
        self.display = display
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(display)
        registerForDraggedTypes([.fileURL])
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canImport() ? .copy : []
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard canImport(), let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        importFiles(urls)
        return true
    }
    required init?(coder: NSCoder) { nil }

    var availableDisplaySize: NSSize {
        NSSize(width: max(1, bounds.width),
               height: max(1, bounds.height - headerHeight - Self.displayGap))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let header = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
            .insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: header, xRadius: headerHeight / 2, yRadius: headerHeight / 2)
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.28, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func layout() {
        super.layout()
        let intrinsic = display.intrinsicContentSize
        let size = intrinsic.width > 0 && intrinsic.height > 0 ? intrinsic : display.frame.size
        let available = NSRect(origin: .zero, size: availableDisplaySize)
        display.frame = NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                               width: size.width, height: size.height)
        needsDisplay = true
    }
}

enum CaptureFile {
    @MainActor
    static func write(to destination: URL, extension suffix: String,
                      produce: (URL) async throws -> Void) async throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".neo-simulator-\(UUID().uuidString).\(suffix)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        do {
            try await produce(temporary)
            try Task.checkCancellation()
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if FileManager.default.fileExists(atPath: temporary.path) {
                do { try FileManager.default.removeItem(at: temporary) }
                catch let cleanup {
                    throw HostError.operation("\(error.localizedDescription) Temporary file remains at \(temporary.path): \(cleanup.localizedDescription)")
                }
            }
            throw error
        }
    }
}
