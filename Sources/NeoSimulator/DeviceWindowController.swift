import AppKit
import UniformTypeIdentifiers

@MainActor
final class DeviceWindowController: NSWindowController, NSWindowDelegate {
    /// The device's current connection. A restart replaces it after the
    /// device boots again, keeping this window.
    private(set) var session: DeviceSession
    private(set) var showsDeviceBezel = true
    private var closed = false
    private var didReadOrientation = false
    private let onClose: (DeviceWindowController, DeviceLifetimeChoice?) -> Void
    /// The choice File ▸ Close Window… made for this close, which takes
    /// precedence over the default close action.
    private var closeChoice: DeviceLifetimeChoice?
    private let onRestart: (DeviceWindowController, _ erasing: Bool) -> Void
    private var content: DeviceContentView
    private var deviceToolbar: DeviceToolbar?
    private var commandKeyUpMonitor: Any?
    var staysOnTop: Bool { window?.level == .floating }
    var canFitScreen: Bool {
        session.canPerformCommands && window?.inLiveResize == false && window?.styleMask.contains(.fullScreen) == false
    }

    init(session: DeviceSession, onClose: @escaping (DeviceWindowController, DeviceLifetimeChoice?) -> Void,
         onRestart: @escaping (DeviceWindowController, _ erasing: Bool) -> Void = { _, _ in }) throws {
        self.session = session
        self.onClose = onClose
        self.onRestart = onRestart
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
        attachSession()
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

    /// Connects the window's toolbar, content, and display events to `session`.
    private func attachSession() {
        guard let window else { return }
        let toolbar = DeviceToolbar(controller: self)
        deviceToolbar = toolbar
        window.toolbar = toolbar.toolbar
        session.display.onPropertiesChange = { [weak self] in self?.displayPropertiesChanged() }
        content.canImport = { [weak self] in self?.session.canPerformToolOperation == true }
        content.importFiles = { [weak self] in self?.importFiles($0) }
        window.contentView = content
    }

    // MARK: Restart

    /// Finishes an active recording, then disconnects from the device so that
    /// it can shut down. The window stays open for `reconnect(_:)`.
    func prepareForRestart() async {
        await session.finishRecording()
        guard !closed else { return }
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        session.disconnect()
        window?.subtitle = "Restarting…"
    }

    /// Shows the device again after a restart, through its new connection.
    func reconnect(_ session: DeviceSession) {
        guard !closed else {
            session.disconnect()
            return
        }
        self.session = session
        content = DeviceContentView(display: session.display.view)
        attachSession()
        if let window {
            (window.title, window.subtitle) = deviceWindowTitles(
                name: session.device.name, runtimeName: session.device.runtimeName)
        }
        session.display.setChromeVisible(showsDeviceBezel)
        didReadOrientation = false
        fitScreen()
        showAndActivate()
        // A window that stayed key gets no new key notification.
        if window?.isKeyWindow == true { activateDisplay() }
    }

    func showAndActivate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if !didReadOrientation, session.capabilities.controlsOrientation {
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

    func restart() { onRestart(self, false) }

    func eraseAllContentAndSettings() {
        guard let window, session.reserve() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Erase all content and settings on \(session.device.name)?"
        alert.informativeText = "The device restarts, and all of its apps, data, and settings are removed."
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.session.release()
            guard response == .alertFirstButtonReturn, !self.closed else { return }
            self.onRestart(self, true)
        }
    }

    func toggleDeviceBezel() {
        showsDeviceBezel.toggle()
        session.display.setChromeVisible(showsDeviceBezel)
        resizeDisplay()
    }

    func toggleStayOnTop() { window?.level = staysOnTop ? .normal : .floating }

    /// Whether captures apply the device's mask by default: the device has
    /// one and `ScreenShotUseMask` is on.
    private var usesDeviceMask: Bool {
        session.capabilities.hasFramebufferMask && UserDefaults.standard.bool(forKey: HostPreferences.screenShotUseMask)
    }

    /// File ▸ Save Screen: captures the screen without asking and shows its
    /// thumbnail, which saves it to the screenshot folder when dismissed.
    func saveScreen() {
        let name = CaptureFile.screenshotName(device: session.device.name, date: Date())
        let folder = CaptureFile.screenshotFolder()
        let mask: DeviceTools.ScreenMask = usesDeviceMask ? .alpha : .ignored
        session.run({ [weak self, session] in
            let file = try await session.screenshot(mask: mask)
            let capture = CapturedContent(.screenshot, file: file, name: name, defaultFolder: folder)
            guard let self else {
                try capture.saveToDefaultLocation()
                return
            }
            try self.showThumbnail(of: capture, image: NSImage(contentsOf: file))
        }, failure: { [weak self] in self?.present($0) })
    }

    /// Shows a capture's thumbnail beside this window, or saves the capture
    /// when the window has closed.
    private func showThumbnail(of capture: CapturedContent, image: NSImage?) throws {
        guard !closed, let window, window.isVisible, !CaptureThumbnail.savesImmediately else {
            try capture.saveToDefaultLocation()
            return
        }
        let display = session.display.view, screen = session.display.inputView
        // The thumbnail shrinks from the device screen, without the bezel.
        let source = window.convertToScreen(screen.convert(screen.bounds, to: nil))
        let displayFrame = window.convertToScreen(display.convert(display.bounds, to: nil))
        // Simulator.app spaces a screenshot's thumbnail by the window's scale,
        // twice as far for a landscape display, a TV, or a watch; in full
        // screen, from the display's right edge.
        let scale = session.display.naturalSize.width > 0 ? display.bounds.width / session.display.naturalSize.width : 1
        let landscape = abs(session.displayAngle.truncatingRemainder(dividingBy: 180)) == 90
        let family = session.capabilities.family
        let base: CGFloat = landscape || family == .tv || family == .watch ? 20 : 10
        let horizontal = window.styleMask.contains(.fullScreen) ? displayFrame.maxX - source.maxX + 10 : 10
        let thumbnail = CaptureThumbnail(capture, image: image, parent: window, source: source,
                                         rotation: session.displayAngle,
                                         cornerRadius: session.capabilities.screenCornerRadius * scale,
                                         spacing: NSSize(width: horizontal, height: ceil(scale * base))) { [weak self] error in
            if let self, !self.closed { self.present(error) } else { CaptureThumbnail.reportDetached(error) }
        }
        thumbnail.show()
    }

    /// File ▸ Save Screen…: asks where to save, starting in the screenshot
    /// folder, and whether to apply the device's mask. Saving remembers both.
    func chooseScreenshotDestination() {
        guard let window, session.reserve() else { return }
        let hasMask = session.capabilities.hasFramebufferMask
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.directoryURL = CaptureFile.screenshotFolder()
        panel.nameFieldStringValue = CaptureFile.screenshotName(device: session.device.name, date: Date())
        let applyMask = NSButton(checkboxWithTitle: "Apply device mask to screenshot", target: nil, action: nil)
        applyMask.toolTip = "Apply device mask to non-rectangular screens when taking screenshots."
        applyMask.state = UserDefaults.standard.bool(forKey: HostPreferences.screenShotUseMask) ? .on : .off
        if hasMask { panel.accessoryView = Self.accessory(applyMask) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.session.release()
            guard response == .OK, let destination = panel.url, !self.closed else { return }
            let useMask = hasMask && applyMask.state == .on
            UserDefaults.standard.set(destination.deletingLastPathComponent().path,
                                      forKey: HostPreferences.screenShotSaveLocation)
            if hasMask { UserDefaults.standard.set(useMask, forKey: HostPreferences.screenShotUseMask) }
            self.session.run({ [session] in try await session.saveScreenshot(to: destination, mask: useMask ? .alpha : .ignored) },
                             failure: { [weak self] in self?.present($0) })
        }
    }

    /// Edit ▸ Copy Screen: puts a PNG of the screen on the Mac pasteboard,
    /// leaving the simulator's pasteboard alone.
    func copyScreen() {
        session.run({ [session] in
            let png = try await session.screenPNG()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
        }, failure: { [weak self] in self?.present($0) })
    }

    /// File ▸ Record Screen: starts recording without asking. Stopping shows
    /// the movie's thumbnail, which saves it to the Desktop when dismissed;
    /// the movie is named when the recording stops.
    func recordScreen() {
        guard let desktop = CaptureFile.desktop else {
            present(HostError.operation("Could not find the Desktop folder to save the recording in."))
            return
        }
        let device = session.device.name
        let isReserved = session.isRecordingDestination
        run {
            try session.startRecording(to: .capture { [weak self] file in
                let capture = CapturedContent(.movie, file: file, name: CaptureFile.recordingName(device: device, date: Date()),
                                              defaultFolder: desktop, isReserved: isReserved)
                if let self { try self.showThumbnail(of: capture, image: nil) } else { try capture.saveToDefaultLocation() }
            }, mask: usesDeviceMask ? .black : .ignored)
        }
    }

    /// File ▸ Record Screen…: asks where to save the movie and whether to
    /// apply the device's mask, then starts recording.
    func chooseRecordingDestination() {
        guard let window, session.reserve() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = CaptureFile.recordingName(device: session.device.name, date: Date())
        // Simulator.app starts this option on and does not remember it.
        let applyMask = NSButton(checkboxWithTitle: "Apply device mask to recording", target: nil, action: nil)
        applyMask.state = .on
        panel.accessoryView = Self.accessory(applyMask)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.session.release()
            guard response == .OK, let destination = panel.url, !self.closed else { return }
            self.run { try self.session.startRecording(to: .file(destination), mask: applyMask.state == .on ? .black : .ignored) }
        }
    }

    private static func accessory(_ option: NSButton) -> NSView {
        let view = NSView()
        option.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(option)
        NSLayoutConstraint.activate([
            option.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            option.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            option.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            option.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        return view
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
        let enabled = UserDefaults.standard.bool(forKey: HostPreferences.rotateWindowWhenSignaledByGuest)
        guard !closed, session.followGuestInterfaceOrientation(enabled: enabled) else { return }
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

    func windowDidBecomeKey(_ notification: Notification) { activateDisplay() }

    private func activateDisplay() {
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
    /// File ▸ Close Window…: asks whether to shut the device down, and closes
    /// the window unless the choice is Cancel.
    func closeAsking() {
        guard let window, window.attachedSheet == nil, !closed else { return }
        let alert = DeviceLifetimeChoice.alert(
            quitting: false, keepsRunningByDefault: UserDefaults.standard.bool(forKey: HostPreferences.detachOnWindowClose))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, let choice = DeviceLifetimeChoice.choice(
                for: response, of: alert, rememberingAs: HostPreferences.detachOnWindowClose) else { return }
            self.closeChoice = choice
            self.window?.close()
        }
    }

    // Like Simulator.app, closing with Control held asks first.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard NSEvent.modifierFlags.contains(.control) else { return true }
        closeAsking()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        disconnect()
        onClose(self, closeChoice)
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
    /// Simulator.app's screenshot name, dated in the local time zone.
    static func screenshotName(device: String, date: Date) -> String {
        name("Simulator Screenshot", device: device, date: date, extension: "png")
    }

    /// Simulator.app's screen recording name, dated in the local time zone.
    static func recordingName(device: String, date: Date) -> String {
        name("Simulator Screen Recording", device: device, date: date, extension: "mov")
    }

    // `:` and `/` become `.`, so a date reads `2026-10-21 at 23.17.05`.
    private static func name(_ kind: String, device: String, date: Date, extension suffix: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH:mm:ss"
        return "\(kind) - \(device) - \(formatter.string(from: date)).\(suffix)"
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: ".")
    }

    static var desktop: URL? { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first }

    /// The folder Save Screen saves into, as Simulator.app chooses it:
    /// `ScreenShotSaveLocation` when it is an existing folder, else the
    /// Desktop, else `/private/tmp`.
    static func screenshotFolder() -> URL {
        if let location = UserDefaults.standard.string(forKey: HostPreferences.screenShotSaveLocation) {
            let path = NSString(string: location).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return desktop ?? URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    }

    /// The first of `name`, "name #2" through "name #99" that is free in `folder`.
    static func unusedFile(in folder: URL, named name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension, suffix = (name as NSString).pathExtension
        for number in 1...99 {
            let candidate = folder.appendingPathComponent(number == 1 ? name : "\(base) #\(number).\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw HostError.operation("Could not save \(name): \(folder.path) already has files of that name through #99.")
    }

    /// Moves a capture into `folder` under `name`, adding " #2" through
    /// " #99" before the extension when the name is taken or `isReserved`.
    /// A failure leaves the capture where it is and names that location.
    static func move(_ capture: URL, into folder: URL, named name: String,
                     isReserved: (URL) -> Bool = { _ in false }) throws -> URL {
        let base = (name as NSString).deletingPathExtension, suffix = (name as NSString).pathExtension
        for number in 1...99 {
            let candidate = folder.appendingPathComponent(number == 1 ? name : "\(base) #\(number).\(suffix)")
            if isReserved(candidate) { continue }
            do {
                try FileManager.default.moveItem(at: capture, to: candidate)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                throw HostError.operation("Could not save \(name) in \(folder.path): \(error.localizedDescription) The capture is at \(capture.path).")
            }
        }
        throw HostError.operation("Could not save \(name): \(folder.path) already has files of that name through #99. The capture is at \(capture.path).")
    }

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

/// Simulator.app's choice between shutting devices down and leaving them
/// running, which File ▸ Close Window… and Quit NeoSimulator… ask for.
enum DeviceLifetimeChoice: Equatable {
    case shutDown, keepRunning

    /// The alert with Simulator.app's text. Return chooses the default action.
    static func alert(quitting: Bool, keepsRunningByDefault: Bool) -> NSAlert {
        let alert = NSAlert()
        if quitting {
            alert.messageText = "Do you want to shut down the simulated devices?"
            alert.informativeText = "You may choose to shut down all running simulated devices or keep them running."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Do you want to shutdown the simulated device?"
            alert.informativeText = "When closing a window, you can either shut down the device or keep it running."
        }
        alert.addButton(withTitle: quitting ? "Shut Down" : "Shut down")
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title =
            quitting ? "Remember as the default quit action." : "Remember as the default close action."
        if keepsRunningByDefault {
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
        }
        return alert
    }

    /// The choice an alert response names, saved as the default under `key`
    /// when the suppression box is checked. Cancel names none.
    static func choice(for response: NSApplication.ModalResponse, of alert: NSAlert,
                       rememberingAs key: String) -> Self? {
        let choice: Self
        switch response {
        case .alertFirstButtonReturn: choice = .shutDown
        case .alertSecondButtonReturn: choice = .keepRunning
        default: return nil
        }
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(choice == .keepRunning, forKey: key) }
        return choice
    }
}
