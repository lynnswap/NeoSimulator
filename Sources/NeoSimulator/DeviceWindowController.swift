import AppKit
import UniformTypeIdentifiers

@MainActor
final class DeviceWindowController: NSWindowController, NSWindowDelegate {
    let session: DeviceSession
    private(set) var showsDeviceBezel = true
    private var closed = false
    private var didReadOrientation = false
    private let onClose: (String) -> Void
    private let content: DeviceContentView
    private var deviceToolbar: DeviceToolbar?
    private var commandKeyUpMonitor: Any?
    var staysOnTop: Bool { window?.level == .floating }
    var canFitScreen: Bool {
        session.canPerformCommands && window?.inLiveResize == false && window?.styleMask.contains(.fullScreen) == false
    }

    init(session: DeviceSession, onClose: @escaping (String) -> Void) throws {
        self.session = session
        self.onClose = onClose
        content = DeviceContentView(display: session.display.view)
        let natural = session.display.naturalSize
        guard natural.width > 0, natural.height > 0 else {
            session.disconnect()
            throw HostError.unavailable("Simulator display has no usable size")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        (window.title, window.subtitle) = deviceWindowTitles(name: session.device.name, runtimeName: session.device.runtimeName)
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
        let toolbar = DeviceToolbar(controller: self)
        deviceToolbar = toolbar
        window.toolbar = toolbar.toolbar
        session.display.onPropertiesChange = { [weak self] in self?.displayPropertiesChanged() }
        content.canImport = { [weak self] in self?.session.canPerformToolOperation == true }
        content.importFiles = { [weak self] in self?.importFiles($0) }
        window.contentView = content
        window.contentMinSize = NSSize(width: 320, height: 300)
        // AppKit never dispatches key-ups while Command is held; forward them
        // so the simulator does not keep the key pressed.
        commandKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command), event.window === self.window,
                self.window?.firstResponder === self.session.display.inputView else { return event }
            self.session.display.inputView.keyUp(with: event)
            return nil
        }
        fitScreen()
    }

    required init?(coder: NSCoder) { nil }

    func showAndActivate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if !didReadOrientation {
            didReadOrientation = true
            session.run({ [weak self] in
                guard let self else { return }
                try await self.session.readOrientation()
                self.didRotate()
            }, failure: { hostLog($0.localizedDescription) })
        }
    }

    // MARK: Commands

    func perform(_ id: DeviceCommand.ID) {
        let command = DeviceCommand.command(id)
        guard !closed, command.isSupported(session.capabilities), command.isEnabled(self) else { return }
        command.perform(self)
        focusInput()
    }

    func send(_ input: HardwareInput) { session.send(input) { [weak self] in self?.present($0) } }

    /// Runs an immediate device action and presents its failure on this window.
    func run(_ action: () throws -> Void) {
        do { try action() } catch { present(error) }
    }

    func rotate(left: Bool) {
        session.run({ [weak self] in
            guard let self else { return }
            try await self.session.rotate(left: left)
            self.didRotate()
        }, failure: { [weak self] in self?.present($0) })
    }

    func setOrientation(_ orientation: DeviceOrientation) {
        session.run({ [weak self] in
            guard let self else { return }
            try await self.session.setOrientation(orientation)
            self.didRotate()
        }, failure: { [weak self] in self?.present($0) })
    }

    func shutDown() {
        session.run({ [session] in try await session.shutDown() }, failure: { [weak self] in self?.present($0) })
    }

    func toggleDeviceBezel() {
        showsDeviceBezel.toggle()
        session.display.setChromeVisible(showsDeviceBezel)
        resizeDisplay()
    }

    func toggleStayOnTop() { window?.level = staysOnTop ? .normal : .floating }

    func saveScreenshot() {
        guard let window, session.reserve() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Simulator Screenshot.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.session.release()
            guard response == .OK, let destination = panel.url, !self.closed else { return }
            self.session.run({ [session] in try await session.saveScreenshot(to: destination) },
                             failure: { [weak self] in self?.present($0) })
        }
    }

    func chooseRecordingDestination() {
        guard let window, session.reserve() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Simulator Recording.mp4"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.session.release()
            guard response == .OK, let destination = panel.url, !self.closed else { return }
            do { try self.session.startRecording(to: destination) }
            catch { self.present(error) }
        }
    }

    func chooseFilesToImport() {
        guard let window, session.reserve() else { return }
        let panel = NSOpenPanel()
        panel.title = "Install App or Import Media"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.applicationBundle, .image, .movie, .vCard]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.session.release()
            if response == .OK, !self.closed { self.importFiles(panel.urls) }
        }
    }

    private func importFiles(_ urls: [URL]) {
        session.run({ [session] in try await session.importFiles(urls) }, failure: { [weak self] in self?.present($0) })
    }

    func chooseURLToOpen() {
        guard let window, session.reserve() else { return }
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
            self.session.release()
            guard response == .alertFirstButtonReturn, !self.closed else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text), url.scheme != nil else {
                self.present(HostError.operation("Enter a URL with a scheme, such as https://example.com"))
                return
            }
            self.session.run({ [session] in try await session.openURL(url) }, failure: { [weak self] in self?.present($0) })
        }
    }

    // MARK: Presentation

    // With Rotate Device Automatically on, the display follows the guest's
    // interface orientation and the window follows the display. Other
    // property changes, such as the backlight, keep the window size.
    private func displayPropertiesChanged() {
        guard !closed, UserDefaults.standard.bool(forKey: HostPreferences.rotateWindowWhenSignaledByGuest),
              session.followGuestInterfaceOrientation() else { return }
        didRotate()
    }

    private func didRotate() {
        fitScreen()
        resizeDisplay()
    }

    func fitScreen() {
        guard let window, !window.inLiveResize, !window.styleMask.contains(.fullScreen) else { return }
        let natural = session.display.naturalSize
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
        session.display.resize(to: content.availableDisplaySize)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        window?.invalidateShadow()
    }

    func focusInput() {
        guard session.canPerformCommands, let window else { return }
        let input = session.display.inputView
        window.makeFirstResponder(input)
        guard window.firstResponder === input else {
            hostLog("Could not focus simulator input for \(session.device.id)")
            return
        }
        // Reconcile modifier releases received while another window owned focus.
        if let event = NSEvent.keyEvent(with: .flagsChanged, location: window.mouseLocationOutsideOfEventStream,
            modifierFlags: NSEvent.modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0) {
            input.flagsChanged(with: event)
        }
    }

    // SimulatorKit applies modifier changes to every display with keyboard input and releases
    // them only on displays that keep it. Sync them when this display gains keyboard input,
    // and release them before it loses it.
    private func sendModifiers(_ flags: NSEvent.ModifierFlags) {
        guard let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0) else { return }
        NSApp.sendEvent(event)
    }

    func present(_ error: Error) {
        guard !closed, let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !closed else { return }
        session.display.setActive(true)
        session.display.setKeyboardEnabled(true)
        sendModifiers(NSEvent.modifierFlags)
        focusInput()
    }
    func windowDidResignKey(_ notification: Notification) {
        guard !closed else { return }
        sendModifiers([])
        session.display.setKeyboardEnabled(false)
        session.display.setActive(false)
    }
    func windowWillStartLiveResize(_ notification: Notification) { if !closed { session.display.beginResize() } }
    func windowDidResize(_ notification: Notification) { resizeDisplay() }
    func windowDidEndLiveResize(_ notification: Notification) {
        if !closed { resizeDisplay(); session.display.endResize() }
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        disconnect()
        onClose(session.device.id)
    }
    func invalidate() {
        disconnect()
        window?.delegate = nil
        window?.close()
    }
    private func disconnect() {
        guard !closed else { return }
        closed = true
        if let commandKeyUpMonitor { NSEvent.removeMonitor(commandKeyUpMonitor) }
        commandKeyUpMonitor = nil
        if let window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
        }
        session.disconnect()
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
