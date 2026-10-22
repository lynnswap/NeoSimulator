import AppKit
import UniformTypeIdentifiers

@MainActor
final class DeviceWindowController: NSWindowController, NSWindowDelegate, DisplayScaling {
    /// The device's current connection. A restart replaces it after the
    /// device boots again, keeping this window.
    private(set) var session: DeviceSession
    private var closed = false
    /// Set from a restart's start until the device's next connection, like
    /// Simulator.app's `isRebooting`. Closing the window meanwhile saves no
    /// geometry.
    private var isRestarting = false
    private var didReadOrientation = false
    private let onClose: (DeviceWindowController, DeviceLifetimeChoice?) -> Void
    /// The choice File ▸ Close Window… made for this close, which takes
    /// precedence over the default close action.
    private var closeChoice: DeviceLifetimeChoice?
    private let onRestart: (DeviceWindowController, _ erasing: Bool) -> Void
    private var content: DeviceContentView
    private let fitting: DisplayFitting
    private let keyboard: DisplayKeyboardInput
    private var deviceToolbar: DeviceToolbar?
    private var customLocation: CustomLocationWindowController?
    /// Keeps where each device's window closes and its display scale.
    private let preferences: any PreferenceStore
    /// Where the device's window last closed in the current arrangement of
    /// screens, which a new window is centered at.
    private let savedCenter: NSPoint?
    /// The display scale the device's window last closed at in the current
    /// arrangement of screens.
    private let savedScale: CGFloat?
    /// How a new window is placed until the first orientation reading, and
    /// the frame it has while only that placement and the guest's rotations
    /// have changed it.
    private var initialPlacement: (place: ((NSWindow) -> Void)?, frame: NSRect)?
    /// Whether the window is in full screen or moving into or out of it,
    /// where Simulator.app's scale commands are unavailable and the bezel
    /// shows no resize cursors.
    private var isFullScreen: Bool { fitting.isFullScreen }
    /// The drag on a corner of the bezel in progress, and the largest scale it
    /// may give the display.
    private var bezelResize: (drag: BezelResize, maximumScale: CGFloat)?
    /// Moves the window with the drag that a press on the bezel begins: by
    /// default AppKit's `performDrag(with:)`, which hands the drag to the
    /// window server.
    private let performWindowDrag: (NSWindow, NSEvent) -> Void
    private var screenParametersObserver: (any NSObjectProtocol)?
    /// Set while the window takes the size of a chosen display scale, which
    /// the resize must not change.
    private var isSizingWindow = false
    /// The title bar's height for each toolbar style, as the window last laid
    /// it out, and macOS 26's heights for the styles it has not taken yet.
    private var titleBarHeights: [NSWindow.ToolbarStyle: CGFloat] = [.unified: 52, .expanded: 76, .unifiedCompact: 40]
    /// I/O ▸ Touch Pressure's app-wide settings, which every window shares.
    let touchPressure: TouchPressure
    private var touchPressureObserver: (any NSObjectProtocol)?
    private var touchIndicatorObserver: (any NSObjectProtocol)?
    private var keyboardSelectionObserver: (any NSObjectProtocol)?
    private var audioRouteObserver: (any NSObjectProtocol)?
    /// Whether the window is key, which makes its device the one that
    /// Simulator.app's keyboard controller types into and that a change of
    /// the Mac's input source applies to.
    private var isKey = false
    /// The window of the device's external display while the display is on.
    private(set) var externalDisplayWindow: ExternalDisplayWindowController?
    /// How often and how long the window looks for its display's
    /// user-interface plugin.
    private let userInterfacePluginLookUp: (attempts: Int, interval: Duration)
    var staysOnTop: Bool { window?.level == .floating }

    /// The device window of the key window: the key device window, or the
    /// device window of the key external display window, whose device the
    /// menus act on, as Simulator.app's device coordinator handles both.
    static var keyDeviceWindow: DeviceWindowController? {
        switch NSApp.keyWindow?.windowController {
        case let controller as DeviceWindowController: controller
        case let controller as ExternalDisplayWindowController: controller.deviceWindow
        default: nil
        }
    }

    init(session: DeviceSession, preferences: any PreferenceStore = UserDefaults.standard,
         touchPressure: TouchPressure,
         performWindowDrag: @escaping (NSWindow, NSEvent) -> Void = { $0.performDrag(with: $1) },
         userInterfacePluginLookUp: (attempts: Int, interval: Duration) = (40, .milliseconds(250)),
         onClose: @escaping (DeviceWindowController, DeviceLifetimeChoice?) -> Void,
         onRestart: @escaping (DeviceWindowController, _ erasing: Bool) -> Void = { _, _ in }) throws {
        self.session = session
        self.userInterfacePluginLookUp = userInterfacePluginLookUp
        self.preferences = preferences
        self.touchPressure = touchPressure
        self.performWindowDrag = performWindowDrag
        // Like Simulator.app, the window's geometry is read once, when it
        // connects, for the current arrangement of screens.
        let saved = preferences.windowGeometry(forDevice: session.device.id, screens: Self.screenFrames)
        savedCenter = saved.center
        savedScale = saved.scale
        self.onClose = onClose
        self.onRestart = onRestart
        content = DeviceContentView(display: session.display.view)
        let natural = session.display.size(for: 1)
        guard natural.width > 0, natural.height > 0 else {
            session.disconnect()
            throw HostError.unavailable("Simulator display has no usable size")
        }
        // Like Simulator.app's window, it starts 500 points wide, which gives
        // the toolbar its first style before the display takes its first scale.
        let window = DeviceWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        fitting = DisplayFitting(display: session.display, content: content)
        keyboard = DisplayKeyboardInput(window: window, display: session.display)
        super.init(window: window)
        (window.title, window.subtitle) = deviceWindowTitles(name: session.device.name, runtimeName: session.device.runtimeName)
        window.appearance = NSAppearance(named: .darkAqua)
        // As in Simulator.app's window, AppKit draws the title bar, which is
        // not transparent: see `updateHeaderShape()`.
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        // Like Simulator.app, full screen stays available while a bezel makes
        // the window not resizable.
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        window.delegate = self
        window.displayScale = { [weak self] in self?.session.display.renderScale ?? 1 }
        window.handleMouseEvent = { [weak self] in self?.handleBezelDrag($0) ?? false }
        attachSession()
        // Like Simulator.app, each window shows the bezel as the app-wide
        // Show Device Bezels preference says, before it takes its scale.
        session.display.setChromeVisible(preferences.showsDeviceBezels)
        bezelChanged()
        updateToolbarStyle(forWidth: window.frame.width)
        // The smallest size a manual resize leaves the window at.
        window.contentMinSize = NSSize(width: 320, height: 300)
        // Like Simulator.app, a change to the screens, such as a display
        // removed or the Dock resized, moves the window back inside its screen.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.moveWindowOntoScreen() }
        }
        touchPressureObserver = NotificationCenter.default.addObserver(
            forName: TouchPressure.didChangeNotification, object: touchPressure, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.touchPressureChanged() }
        }
        // Like Simulator.app, each open window follows the touch indicator
        // preferences when they change.
        touchIndicatorObserver = NotificationCenter.default.addObserver(
            forName: TouchIndicator.didChangeNotification, object: preferences, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showTouchIndicators() }
        }
        keyboardSelectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardSelectionChanged() }
        }
        // Like Simulator.app, an audio route chosen in any window applies to
        // every device window.
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AudioRouting.didChangeNotification, object: preferences, queue: .main) { [weak self] notification in
            let scope = (notification.userInfo?[AudioRouting.scopeKey] as? UInt64).flatMap(AudioScope.init(rawValue:))
            MainActor.assumeIsolated { if let scope { self?.audioRouteChosen(in: scope) } }
        }
        showDisplay(fitting: { self.initialScale })
    }

    /// Like Simulator.app, a new window opens at the saved scale or Point
    /// Accurate, reduced to Fit Screen's.
    private var initialScale: CGFloat { min(scale(for: .fitScreen) ?? .infinity, savedScale ?? 1) }

    /// Shows the display at the scale `scale` gives, and again at the smaller
    /// one it gives when the first made the window narrow enough to take the
    /// taller expanded title bar. Simulator.app measures Fit Screen with the
    /// title bar the window has before the change, so such a window ends up
    /// taller than the screen there.
    private func showDisplay(fitting scale: () -> CGFloat?) {
        guard let first = scale() else { return }
        showDisplay(at: first)
        if let second = scale(), second < first { showDisplay(at: second) }
    }

    /// Gives a new window its initial scale and places it with `place`, again
    /// when that scale gave it the taller expanded title bar, as
    /// `showDisplay(fitting:)` does.
    private func placeAtInitialScale(_ place: ((NSWindow) -> Void)?) {
        let scale = initialScale
        session.display.setRenderScale(scale)
        didRotate(placing: place)
        let refit = initialScale
        guard refit < scale else { return }
        session.display.setRenderScale(refit)
        didRotate(placing: place)
    }

    /// The frames of the Mac's screens, whose arrangement keys the saved
    /// window geometry.
    private static var screenFrames: [NSRect] { NSScreen.screens.map(\.frame) }

    /// Shows a new window where Simulator.app places it: centered where the
    /// device's window last closed in the current arrangement of screens, or
    /// else cascading from `cascadePoint`, which the first window takes from
    /// the center of the screen. The window then moves back inside the
    /// screen where it crosses an edge.
    ///
    /// Simulator.app turns the display to the device's orientation before
    /// choosing the window's scale and placing it. NeoSimulator reads the
    /// orientation afterwards, so that reading gives the window the scale it
    /// opens at in its new shape and places a centered window again, unless
    /// the window has moved or changed size in the meantime. A window that
    /// cascades from another keeps its top-left corner, as there.
    func showNewWindow(cascadingFrom cascadePoint: inout NSPoint) {
        guard let window else { return }
        let place: ((NSWindow) -> Void)?
        if let center = savedCenter {
            place = { $0.setFrameOrigin(NSPoint(x: center.x - $0.frame.width * 0.5, y: center.y - $0.frame.height * 0.5)) }
            place?(window)
        } else {
            place = cascadePoint == .zero ? { $0.center() } : nil
            place?(window)
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        // The window opened at the scale for the main screen; it takes the
        // scale for the screen it is placed on.
        placeAtInitialScale(place)
        initialPlacement = (place, window.frame)
        readInitialOrientation()
    }

    required init?(coder: NSCoder) { nil }

    /// Connects the window's toolbar, content, and display events to `session`.
    private func attachSession() {
        guard let window else { return }
        let toolbar = DeviceToolbar(controller: self)
        deviceToolbar = toolbar
        toolbar.attach(to: window)
        session.display.onPropertiesChange = { [weak self] in self?.displayPropertiesChanged() }
        session.onExternalScreenChange = { [weak self] in self?.syncExternalDisplayWindow() }
        content.canImport = { [weak self] in self?.session.canPerformToolOperation == true }
        content.importFiles = { [weak self] in self?.importFiles($0) }
        window.contentView = content
        showResizeCursors()
        connectTouchPressure()
        showTouchIndicators()
        session.followBacklight()
        attachUserInterfacePlugin()
    }

    // MARK: User-interface plugin

    private var pluginLookUp: Task<Void, Never>?

    /// Shows the toolbar of the display's user-interface plugin, as
    /// Simulator.app does when SimulatorKit reports the plugin, once the
    /// display has loaded it. SimulatorKit places the plugin's overlay over
    /// the screen itself; the overlay then takes the window's focus. A plugin
    /// that does not load, or that cannot be used, is reported: the device
    /// then shows its screen without the plugin's controls.
    private func attachUserInterfacePlugin() {
        pluginLookUp?.cancel()
        pluginLookUp = nil
        guard session.capabilities.hasUserInterfacePlugin else { return }
        let session = self.session
        let schedule = userInterfacePluginLookUp
        pluginLookUp = Task.immediate { [weak self] in
            for attempt in 1...schedule.attempts {
                guard let self, !self.closed, self.session === session, session.isConnected else { return }
                do {
                    if let plugin = try session.display.userInterfacePlugin() {
                        self.showUserInterfacePlugin(plugin)
                        return
                    }
                } catch {
                    self.present(HostError.operation(
                        "The controls of \(session.device.name) are unavailable: \(error.localizedDescription)"))
                    return
                }
                if attempt < schedule.attempts { try? await Task.sleep(for: schedule.interval) }
            }
            guard let self, !self.closed, self.session === session, session.isConnected else { return }
            self.present(HostError.unavailable(
                "The controls of \(session.device.name) are unavailable: SimulatorKit did not load its user interface plugin."))
        }
    }

    private func showUserInterfacePlugin(_ plugin: SimulatorUserInterfacePlugin) {
        guard let window else { return }
        if let toolbar = plugin.toolbar {
            window.toolbar = toolbar
            // The plugin's toolbar takes the window's toolbar style.
            deviceToolbar?.apply(window.toolbarStyle, to: window)
        }
        // The overlay is the display's input view now.
        if window.isKeyWindow { focusInput() }
    }

    /// Home on a user-interface plugin's toolbar, Simulator.app's
    /// `homeButtonPressed:`.
    @objc func homeButtonPressed(_ sender: Any?) { perform(.home) }

    /// Save Screen on a user-interface plugin's toolbar, Simulator.app's
    /// `saveFramebufferImage:`.
    @objc func saveFramebufferImage(_ sender: Any?) { perform(.saveScreen) }

    /// Save Screen on a user-interface plugin's toolbar with Option, or
    /// while recording, Simulator.app's `toggleVideoRecording:`: starts or
    /// stops recording the screen.
    @objc func toggleVideoRecording(_ sender: Any?) {
        perform(session.recording == nil ? .recordScreen : .stopRecording)
    }

    // MARK: Restart

    /// Finishes an active recording, then disconnects from the device so that
    /// it can shut down. The window stays open for `reconnect(_:)`.
    func prepareForRestart() async {
        isRestarting = true
        await session.finishRecording()
        guard !closed else { return }
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        customLocation?.close()
        closeExternalDisplayWindow()
        session.disconnect()
        fitting.invalidate()
        window?.subtitle = "Restarting…"
    }

    /// Shows the device again after a restart, through its new connection.
    func reconnect(_ session: DeviceSession) {
        guard !closed else {
            session.disconnect()
            return
        }
        // The device's next connection shows a new display at the window's
        // scale. Like Simulator.app, which turns its display upright after a
        // restart, the window takes the display's shape as after a rotation:
        // below its top edge, then moved back inside the screen.
        let scale = WindowScale.usable(self.session.display.renderScale) ?? 1
        isRestarting = false
        self.session = session
        content = DeviceContentView(display: session.display.view)
        fitting.attach(session.display, content: content)
        keyboard.display = session.display
        attachSession()
        if let window {
            (window.title, window.subtitle) = deviceWindowTitles(
                name: session.device.name, runtimeName: session.device.runtimeName)
        }
        session.display.setChromeVisible(preferences.showsDeviceBezels)
        bezelChanged()
        didReadOrientation = false
        session.display.setRenderScale(scale)
        didRotate()
        showAndActivate()
        // A window that stayed key gets no new key notification.
        if window?.isKeyWindow == true { activateDisplay() }
    }

    func showAndActivate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        readInitialOrientation()
    }

    /// Reads the orientation once for each connection and turns the window
    /// to it. A new window that still has its `initialPlacement` frame then
    /// takes the scale it opens at in that shape and is placed again. Like
    /// Simulator.app, which turns only an iPhone's or iPad's display, a
    /// device that does not rotate keeps its upright display.
    private func readInitialOrientation() {
        guard session.capabilities.rotates else {
            initialPlacement = nil
            return
        }
        // A reading in progress keeps the placement for its result.
        guard !didReadOrientation else { return }
        didReadOrientation = true
        session.run({ [weak self] in
            guard let self else { return }
            defer { self.initialPlacement = nil }
            try await self.session.readOrientation()
            if let placement = self.initialPlacement, self.window?.frame == placement.frame {
                self.placeAtInitialScale(placement.place)
            } else {
                self.didRotate()
            }
        }, failure: { [weak self] in
            self?.initialPlacement = nil
            hostLog($0.localizedDescription)
        })
    }

    // MARK: Commands

    func perform(_ id: DeviceCommand.ID) {
        let command = DeviceCommand.command(id)
        guard !closed, command.isSupported(session.capabilities), command.isEnabled(self) else { return }
        command.perform(self)
        if let externalDisplayWindow, externalDisplayWindow.isKey {
            externalDisplayWindow.focusInput()
        } else {
            focusInput()
        }
    }

    func send(_ input: HardwareInput) { session.send(input) { [weak self] in self?.present($0) } }

    /// Runs an immediate device action and presents its failure on this window.
    func run(_ action: () throws -> Void) {
        do { try action() } catch { present(error) }
    }

    /// Debug ▸ Open System Log…. Opening Console is not a device operation, so
    /// it does not take the device-operation slot.
    func openSystemLog() {
        Task { [weak self, session] in
            do { try await session.openSystemLog() } catch { self?.present(error) }
        }
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

    /// Shows or hides the device's bezel for Window ▸ Show Device Bezels, as
    /// Simulator.app's `setShowChrome:` does: the display keeps its scale and
    /// the window takes the display's new size.
    func setDeviceBezelVisible(_ visible: Bool) {
        session.display.setChromeVisible(visible)
        bezelChanged()
        updateWindowSize()
    }

    /// Follows the bezel the display shows, as Simulator.app's chrome refresh
    /// does: AppKit does not resize a window with a bezel, whose corners
    /// resize it instead, the bezel's top padding lets the window extend
    /// above the screen, and the gap above the display is 10 points less
    /// that padding. The window is clear around a bezel, below a title bar
    /// with rounded lower corners. Without a bezel, there is no gap, the title
    /// bar is square, and the window is black, which shows wherever the
    /// display leaves the window uncovered, such as at its rounded corners;
    /// in full screen the window keeps its color and stays resizable until it
    /// leaves full screen.
    private func bezelChanged() {
        guard let window = window as? DeviceWindow else { return }
        let padding = session.display.chromePadding
        content.displayGap = WindowScale.displayGap(bezelPadding: padding)
        window.chromeTopPadding = padding?.height ?? 0
        updateHeaderShape()
        if padding != nil { window.backgroundColor = .clear } else if !isFullScreen { window.backgroundColor = .black }
        guard !isFullScreen else { return }
        if padding == nil { window.styleMask.insert(.resizable) } else { window.styleMask.remove(.resizable) }
    }

    /// Gives the toolbar the style that Simulator.app's geometry update gives
    /// it for a display `width` points wide (see `DeviceToolbar.style`), and
    /// lays the title bar out for that style, so that `content.headerHeight`
    /// is its height. AppKit otherwise lays it out later, and an expanded
    /// title bar would read 8 points taller than it becomes.
    private func updateToolbarStyle(forWidth width: CGFloat) {
        guard let window, let deviceToolbar else { return }
        let titles = deviceWindowTitles(name: session.device.name, runtimeName: session.device.runtimeName)
        deviceToolbar.apply(deviceToolbar.style(forWidth: width, title: titles.title, subtitle: titles.subtitle,
                                                preferences: preferences), to: window)
        window.layoutIfNeeded()
        titleBarHeights[window.toolbarStyle] = content.headerHeight
        updateHeaderShape()
    }

    /// Like Simulator.app, rounds the lower corners of the title bar with the
    /// window's corner radius for its toolbar style while the bezel shows
    /// outside full screen, and squares them otherwise.
    private func updateHeaderShape() {
        (window as? DeviceWindow)?.roundHeader(session.display.chromePadding != nil && !isFullScreen)
    }

    func toggleStayOnTop() {
        window?.level = staysOnTop ? .normal : .floating
        customLocation?.window?.level = window?.level ?? .normal
    }

    // MARK: Keyboard and touch pressure

    /// I/O ▸ Keyboard ▸ Connect Hardware Keyboard. As in Simulator.app, the
    /// device's choice is saved and the Mac's keyboard follows it at once;
    /// the guest's keyboard changes later. A failure is presented.
    func toggleHardwareKeyboard() {
        Task.immediate { [weak self, session] in
            do { try await session.toggleHardwareKeyboard() } catch { self?.present(error) }
        }
        updateKeyboardInput()
        externalDisplayWindow?.updateKeyboardInput()
    }

    /// Gives the display the Mac's keyboard while the window is key and its
    /// device's hardware keyboard is connected, as Simulator.app's keyboard
    /// controller does.
    private func updateKeyboardInput() {
        keyboard.setEnabled(isKey && session.connectsHardwareKeyboard)
    }

    /// Like Simulator.app, a change of the Mac's input source gives the key
    /// device's keyboard its language. Simulator.app ignores a failure; it is
    /// logged. The change starts before this returns, so that changes reach
    /// the device in order.
    private func keyboardSelectionChanged() {
        guard !closed, isKey || externalDisplayWindow?.isKey == true else { return }
        Task.immediate { [session] in
            do { try await session.syncKeyboardLanguage() } catch {
                hostLog("Could not set the keyboard language of \(session.device.name): \(error.localizedDescription)")
            }
        }
    }

    /// Gives a newly connected display I/O ▸ Touch Pressure's settings. Like
    /// Simulator.app, the display takes touch pressure on the device's own
    /// screen when the device does, and the trackpad's force as Use Trackpad
    /// Force says. Simulator.app leaves a new display at Shallow Press,
    /// whatever the menu's checkmark shows; here it takes the app's mode.
    private func connectTouchPressure() {
        let display = session.display
        display.setSupportsTouchPressure(
            display.displayClass == 0 && session.capabilities.supportsFeature(DeviceCapabilities.touchPressure))
        applyTouchPressure()
    }

    /// Like Simulator.app, a change reaches the window of each device that
    /// takes touch pressure.
    private func touchPressureChanged() {
        guard !closed, session.capabilities.supportsFeature(DeviceCapabilities.touchPressure) else { return }
        applyTouchPressure()
    }

    private func applyTouchPressure() {
        session.display.setUsesTrackpadForce(touchPressure.usesTrackpadForce)
        session.display.setSimulatedTouchMode(touchPressure.mode)
    }

    /// Draws the touch indicators that the preferences turn on, and no
    /// others, when the display connects, as Simulator.app's window does,
    /// and after a preference changes.
    private func showTouchIndicators() {
        for indicator in TouchIndicator.allCases {
            session.display.setTouchIndicator(indicator, shown: preferences.showsTouchIndicator(indicator))
        }
    }

    /// Features ▸ Location: Custom Location… asks for a coordinate first.
    func selectLocation(_ selection: LocationSelection) {
        guard !closed, session.canPerformCommands else { return }
        guard selection == .custom else {
            changeLocation { [session] in try await session.selectLocation(selection) }
            focusInput()
            return
        }
        let customLocation = customLocation ?? CustomLocationWindowController { [weak self] latitude, longitude in
            guard let self else { return }
            changeLocation { [session] in try await session.setCustomLocation(latitude: latitude, longitude: longitude) }
        }
        self.customLocation = customLocation
        // The window takes its device window's level, also when Stay on Top
        // changes, so that the device window cannot hide it.
        customLocation.window?.level = window?.level ?? .normal
        let defaults = UserDefaults.standard
        customLocation.show(latitude: defaults.double(forKey: HostPreferences.locationLatitude),
                            longitude: defaults.double(forKey: HostPreferences.locationLongitude))
    }

    /// I/O ▸ Audio Input or Audio Output: saves `route` as the app's most
    /// recent route for `scope`, which every device window then applies.
    func selectAudioRoute(_ route: String, in scope: AudioScope) {
        guard !closed else { return }
        preferences.chooseAudioRoute(route, in: scope)
        focusInput()
    }

    /// Routes the device to the app's new choice, presenting a failure on this window.
    private func audioRouteChosen(in scope: AudioScope) {
        guard !closed else { return }
        session.synchronizeAudioRoute(in: scope) { [weak self] in self?.present($0) }
    }

    /// Starts a location change before returning, so that changes reach the
    /// device in the order they are chosen, and presents its failure on this window.
    private func changeLocation(_ change: @escaping @MainActor () async throws -> Void) {
        Task.immediate { [weak self] in
            do { try await change() } catch { self?.present(error) }
        }
    }

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
        let scale = session.display.renderScale
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

    /// Edit ▸ Get Pasteboard or Send Pasteboard. A failure that the device
    /// reports later is also presented on this window.
    func transferPasteboard(_ transfer: PasteboardTransfer) {
        session.transferPasteboard(transfer) { [weak self] in self?.present($0) }
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

    // MARK: External display

    /// I/O ▸ External Displays. A failure, also one that CoreSimulator
    /// reports later, is presented on this window.
    func chooseExternalDisplay(_ mode: ExternalDisplayMode) {
        guard !closed else { return }
        session.chooseExternalDisplay(mode) { [weak self] in self?.present($0) }
    }

    /// The window that the Window menu's scale commands scale: the external
    /// display's window while it is key, otherwise this one.
    var scaledWindow: any DisplayScaling {
        guard let externalDisplayWindow, externalDisplayWindow.isKey else { return self }
        return externalDisplayWindow
    }

    /// Like Simulator.app's screen monitor, opens the external display's
    /// window while the display is on, whoever turned it on, sizes it to the
    /// display's new size, and closes it once the display is off.
    private func syncExternalDisplayWindow() {
        guard !closed else { return }
        guard let state = session.externalScreen, state.isPoweredOn else { return closeExternalDisplayWindow() }
        if let externalDisplayWindow { return externalDisplayWindow.screenChanged(state) }
        do {
            let controller = try ExternalDisplayWindowController(
                session: session, display: session.makeExternalDisplay(), state: state, deviceWindow: self,
                preferences: preferences) { [weak self] in self?.externalDisplayWindowClosed() }
            externalDisplayWindow = controller
            controller.showNewWindow(cascadingFrom: window)
        } catch {
            present(HostError.operation(
                "Could not show the external display of \(session.device.name): \(error.localizedDescription)"))
        }
    }

    private func closeExternalDisplayWindow() {
        externalDisplayWindow?.invalidate()
        externalDisplayWindow = nil
    }

    /// Like Simulator.app, closing the external display's window chooses
    /// Disabled. When turning the display off fails, its window opens again.
    private func externalDisplayWindowClosed() {
        externalDisplayWindow = nil
        session.chooseExternalDisplay(.disabled) { [weak self] error in
            self?.present(error)
            self?.syncExternalDisplayWindow()
        }
    }

    // MARK: Presentation

    // With Rotate Device Automatically on, the display follows the guest's
    // interface orientation and the window follows the display. Other
    // property changes, such as the backlight, keep the window size.
    private func displayPropertiesChanged() {
        guard !closed else { return }
        session.followBacklight()
        let enabled = UserDefaults.standard.bool(forKey: HostPreferences.rotateWindowWhenSignaledByGuest)
        guard session.followGuestInterfaceOrientation(enabled: enabled) else { return }
        // A guest rotation before the first orientation reading does not
        // count as a change to the new window's placement.
        let untouched = initialPlacement.map { window?.frame == $0.frame } ?? false
        didRotate()
        if untouched, let frame = window?.frame { initialPlacement?.frame = frame }
    }

    /// Like Simulator.app, the rotated display keeps its scale, and the
    /// window takes its new shape below its top edge, moving down when that
    /// edge would be above the screen, or is placed by `place`. The window
    /// then moves back inside the screen where it crosses an edge.
    private func didRotate(placing place: ((NSWindow) -> Void)? = nil) {
        guard !closed, let window, !fitting.fitsWindow else {
            resizeDisplay()
            return
        }
        let previous = window.frame
        updateWindowSize()
        if let place {
            place(window)
        } else {
            let height = window.frame.height
            var y = previous.maxY - height
            if let visible = window.screen?.visibleFrame, visible.maxY < height + y { y -= height + y - visible.maxY }
            window.setFrameOrigin(NSPoint(x: previous.minX.rounded(.toNearestOrEven), y: y.rounded(.toNearestOrEven)))
        }
        moveWindowOntoScreen()
    }

    // MARK: Window scale

    /// The scale `mode` shows the display at in this window, as Simulator.app
    /// computes it, or nil for Fit Screen without a screen.
    func scale(for mode: WindowScaleMode) -> CGFloat? {
        let screen = window?.screen
        switch mode {
        case .physicalSize:
            return WindowScale.physicalSize(hostDensity: screen.flatMap(WindowScale.density(of:)),
                                            deviceDensity: session.capabilities.screenPointsPerInch.map { CGFloat($0) })
        case .pointAccurate:
            return 1
        case .pixelAccurate:
            return WindowScale.pixelAccurate(screenScale: session.display.screenScale,
                                             backingScaleFactor: screen?.backingScaleFactor)
        case .fitScreen:
            // The window keeps 10 points from each edge of the screen.
            guard let space = displaySpace(on: screen ?? NSScreen.main) else { return nil }
            return session.display.scale(for: NSSize(width: space.width - 20, height: space.height - 20))
        }
    }

    /// The largest display that fits `screen` in this window: the visible
    /// frame below the window's header and the gap above the display, which
    /// is the window's frame less the display's in Simulator.app.
    private func displaySpace(on screen: NSScreen?) -> NSSize? {
        guard let visible = screen?.visibleFrame else { return nil }
        return NSSize(width: visible.width, height: visible.height - content.heightAboveDisplay)
    }

    /// The smallest scale that Simulator.app lets a fixed scale or a drag on
    /// the bezel give the display.
    private var minimumScale: CGFloat {
        WindowScale.minimum(family: session.capabilities.family, displayClass: session.display.displayClass,
                            fitting240: session.display.scale(for: NSSize(width: 240, height: 240)))
    }

    /// Whether Simulator.app's validation of a scale command gets past its
    /// first checks: a connected display outside full screen, and for
    /// Physical Size, the device's own screen. Otherwise the command is
    /// unavailable and its checkmark stays as it is.
    private func validatesScale(_ mode: WindowScaleMode) -> Bool {
        session.canPerformCommands && !isFullScreen && (mode != .physicalSize || session.display.displayClass == 0)
    }

    /// Whether a scale command can run, as Simulator.app validates it: on a
    /// connected display outside full screen, Physical Size only on the
    /// device's own screen, and a fixed scale only from the device's minimum.
    /// A display without a bezel must also fit its screen's visible frame
    /// below the window's header, where Simulator.app leaves out the gap
    /// above the display; a window with a bezel may extend past the screen.
    func canSetScale(_ mode: WindowScaleMode) -> Bool {
        guard validatesScale(mode), let window else { return false }
        guard mode != .fitScreen else { return true }
        guard let scale = scale(for: mode), scale >= minimumScale else { return false }
        guard session.display.chromePadding == nil, let visible = window.screen?.visibleFrame else { return true }
        let size = session.display.size(for: scale)
        return size.width <= visible.width && size.height <= visible.height - titleBarHeight(forDisplayWidth: size.width)
    }

    /// The height of the title bar that a window around a display `width`
    /// points wide takes, so that a scale is checked against the title bar it
    /// would have. Simulator.app checks against the title bar the window has,
    /// which a scale that changes the toolbar's style makes 24 points too
    /// short or too tall.
    private func titleBarHeight(forDisplayWidth width: CGFloat) -> CGFloat {
        guard let deviceToolbar else { return content.headerHeight }
        let titles = deviceWindowTitles(name: session.device.name, runtimeName: session.device.runtimeName)
        let style = deviceToolbar.style(forWidth: width, title: titles.title, subtitle: titles.subtitle,
                                        preferences: preferences)
        return titleBarHeights[style] ?? content.headerHeight
    }

    /// The checkmark of a fixed scale: on while the display is at that scale,
    /// also below the device's minimum or past the screen. It follows the
    /// window's screen, so moving the window to a screen with another
    /// resolution or size can clear it. Nil, which leaves the checkmark as it
    /// is, where Simulator.app's validation returns before setting it.
    func scaleState(_ mode: WindowScaleMode) -> NSControl.StateValue? {
        guard validatesScale(mode), let scale = scale(for: mode) else { return nil }
        return WindowScale.matches(session.display.renderScale, scale) ? .on : .off
    }

    /// Shows the display at `mode`'s scale and sizes the window to it below
    /// its top edge. Fit Screen then centers the window on its screen; the
    /// fixed scales move it back inside its screen.
    func setScale(_ mode: WindowScaleMode) {
        guard let window, let scale = scale(for: mode) else { return }
        let previous = window.frame
        if mode == .fitScreen {
            showDisplay(fitting: { self.scale(for: .fitScreen) })
        } else {
            showDisplay(at: scale)
        }
        window.setFrameOrigin(NSPoint(x: previous.minX, y: previous.maxY - window.frame.height))
        guard mode == .fitScreen else {
            moveWindowOntoScreen()
            return
        }
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }

    /// Moves the window inside its screen's visible frame along each axis
    /// where it crosses an edge, as Simulator.app does after a fixed scale, a
    /// rotation, or a change to the screens, and for a new window; not in
    /// full screen.
    private func moveWindowOntoScreen() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let origin = WindowScale.origin(of: window.frame, within: visible)
        if origin != window.frame.origin { window.setFrameOrigin(origin) }
    }

    /// Shows the display at `scale` and sizes the window to it.
    private func showDisplay(at scale: CGFloat) {
        guard !closed else { return }
        session.display.setRenderScale(scale)
        updateWindowSize()
    }

    /// Sizes the window to the display at its scale, as Simulator.app's
    /// geometry update does: the toolbar takes the style for the display's
    /// width, and the window is as wide as the display, also below
    /// `contentMinSize`, and as tall as the display, the gap above it, and the
    /// title bar of that style. It keeps its bottom-left corner or moves it to
    /// `origin`, takes the smallest integral frame around that
    /// (`NSIntegralRect`), and moves down when its top would be above the
    /// screen. In full screen and during a live resize, the display fits the
    /// window instead.
    private func updateWindowSize(origin: NSPoint? = nil) {
        guard !closed, let window, !fitting.fitsWindow else {
            resizeDisplay()
            return
        }
        let size = session.display.size(for: session.display.renderScale)
        updateToolbarStyle(forWidth: size.width)
        let sized = window.frameRect(forContentRect: NSRect(x: 0, y: 0,
            width: size.width, height: size.height + content.heightAboveDisplay))
        content.isSizedToDisplay = true
        setFrame(around: NSRect(origin: origin ?? window.frame.origin, size: sized.size))
        fitting.layout()
    }

    /// Gives the window the smallest integral frame around `frame`
    /// (`NSIntegralRect`), moved down when its top would be above the screen,
    /// as Simulator.app's geometry update does.
    private func setFrame(around frame: NSRect) {
        guard let window else { return }
        var frame = NSIntegralRect(frame)
        if let visible = window.screen?.visibleFrame, visible.maxY < frame.maxY {
            frame.origin.y = visible.maxY - frame.height
        }
        isSizingWindow = true
        window.setFrame(frame, display: true)
        isSizingWindow = false
    }

    // MARK: Bezel dragging

    /// Handles the presses that no view in the window takes, as
    /// Simulator.app's `DeviceWindow` does: a drag on a corner of the bezel,
    /// in `SimDisplayView.typedResizeRects`, resizes the window, and any
    /// other press moves it. Returns whether `event` belongs to such a drag.
    private func handleBezelDrag(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown: return beginBezelResize(with: event) || moveWindow(with: event)
        case .leftMouseDragged where bezelResize != nil: continueBezelResize(with: event)
        case .leftMouseUp where bezelResize != nil: endBezelResize()
        default: return false
        }
        return true
    }

    /// Moves the window with a press that reaches it outside the bezel's
    /// corners while `AllowsMoveByDragOnWindowChrome` is on, outside full
    /// screen. On the display, SimulatorKit passes the window only presses on
    /// the bezel: its digitizer, which also covers the bezel around the
    /// screen, passes on a press there once the pointer moves away from the
    /// screen, and keeps the presses on the screen, as the bezel's buttons
    /// keep theirs. Like Simulator.app, a press that AppKit gives the window
    /// outside the display, such as in the gap below the header, moves it
    /// too; the window server gives a press on the gap's transparent pixels
    /// to the window behind.
    private func moveWindow(with event: NSEvent) -> Bool {
        guard !closed, !isFullScreen, preferences.movesWindowByDraggingBezel, let window else { return false }
        performWindowDrag(window, event)
        return true
    }

    /// Starts a drag when `event` presses a corner of the bezel, outside full
    /// screen. The display may grow until the dragged corner reaches the
    /// edges of the screen's visible frame.
    private func beginBezelResize(with event: NSEvent) -> Bool {
        guard !closed, !isFullScreen, let window else { return false }
        let display = session.display
        let point = display.view.convert(event.locationInWindow, from: nil)
        guard let corner = display.resizeRects.first(where: { $0.rect.contains(point) })?.corner else { return false }
        let drag = BezelResize(corner: corner,
                               start: NSRect(origin: window.frame.origin,
                                             size: NSSize(width: window.frame.width, height: display.view.frame.height)),
                               pointer: Self.screenLocation(of: event, in: window))
        let maximumScale = (window.screen ?? NSScreen.main).map {
            display.scale(for: drag.largestSize(within: $0.visibleFrame))
        } ?? 1000
        bezelResize = (drag, maximumScale)
        display.beginResize()
        return true
    }

    /// Gives the display the largest scale at which it fits the size the drag
    /// asks for, from the device's minimum to the drag's maximum, and moves
    /// the window so that the display's opposite corner stays where it was.
    private func continueBezelResize(with event: NSEvent) {
        guard let resize = bezelResize, let window else { return }
        let display = session.display
        let requested = resize.drag.requestedSize(pointerAt: Self.screenLocation(of: event, in: window))
        display.setRenderScale(min(resize.maximumScale, max(minimumScale, display.scale(for: requested))))
        updateWindowSize(origin: resize.drag.origin(for: display.size(for: display.renderScale)))
    }

    /// Ends the drag. Like Simulator.app, a window that the drag left
    /// mostly off its screen then moves back within reach.
    private func endBezelResize() {
        bezelResize = nil
        session.display.endResize()
        guard let window, !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let origin = WindowScale.origin(of: window.frame, reaching: visible)
        if origin != window.frame.origin { window.setFrameOrigin(origin) }
    }

    /// Where `event` happened on the screen. A window server event keeps
    /// where the pointer was then, unlike its location in the window, which
    /// a move of the window during the drag can leave behind.
    private static func screenLocation(of event: NSEvent, in window: NSWindow) -> NSPoint {
        event.cgEvent?.unflippedLocation ?? window.convertPoint(toScreen: event.locationInWindow)
    }

    /// Shows the bezel's resize cursors outside full screen, as Simulator.app does.
    private func showResizeCursors() {
        session.display.setShowsResizeCursors(!isFullScreen)
        window?.invalidateCursorRects(for: session.display.view)
    }

    private func resizeDisplay() {
        guard !closed else { return }
        fitting.fit()
    }

    func focusInput() {
        guard session.canPerformCommands, window != nil else { return }
        if !keyboard.focus() { hostLog("Could not focus simulator input for \(session.device.id)") }
    }

    func present(_ error: Error) {
        guard !closed, let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }

    func windowDidBecomeKey(_ notification: Notification) { activateDisplay() }

    private func activateDisplay() {
        guard !closed else { return }
        isKey = true
        session.display.setActive(true)
        updateKeyboardInput()
        focusInput()
    }
    func windowDidResignKey(_ notification: Notification) {
        guard !closed else { return }
        isKey = false
        updateKeyboardInput()
        session.display.setActive(false)
    }
    func windowWillStartLiveResize(_ notification: Notification) { if !closed { fitting.willStartLiveResize() } }
    /// Like Simulator.app's `windowDidResize:`, a resize that the window did
    /// not make itself, such as a manual one, gives the toolbar the style for
    /// the new width outside full screen and keeps the window's height below
    /// the title bar. The display then fits the window.
    func windowDidResize(_ notification: Notification) {
        guard !isSizingWindow else { return }
        if !closed, !isFullScreen, let window {
            let below = window.frame.height - content.headerHeight
            updateToolbarStyle(forWidth: window.frame.width)
            let height = below + content.headerHeight
            if height != window.frame.height {
                setFrame(around: NSRect(origin: window.frame.origin, size: NSSize(width: window.frame.width, height: height)))
            }
        }
        resizeDisplay()
    }
    // Simulator.app animates a window with a bezel, which is not resizable,
    // into full screen and back itself. AppKit's transition fills the screen
    // only with a resizable window, so the window is resizable in full screen.
    func windowWillEnterFullScreen(_ notification: Notification) {
        fitting.willEnterFullScreen()
        showResizeCursors()
        updateHeaderShape()
        window?.styleMask.insert(.resizable)
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fitting.didFailToEnterFullScreen()
        showResizeCursors()
        updateHeaderShape()
        bezelChanged()
    }
    /// Like Simulator.app, the window returns to the display's scale and the
    /// window's origin from before full screen, which AppKit's own return does
    /// not keep for a window taller than the screen.
    func windowDidExitFullScreen(_ notification: Notification) {
        let geometry = fitting.didExitFullScreen()
        showResizeCursors()
        updateHeaderShape()
        bezelChanged()
        guard let geometry else { return }
        showDisplay(at: geometry.scale)
        window?.setFrameOrigin(geometry.origin)
        // The screen the window was on may be gone, and the screen changes
        // that happened meanwhile did not move it.
        moveWindowOntoScreen()
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        if !closed { fitting.didEndLiveResize() }
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
        saveWindowGeometry()
        disconnect()
        onClose(self, closeChoice)
    }
    func invalidate() {
        saveWindowGeometry()
        disconnect()
        window?.delegate = nil
        window?.close()
    }
    /// Like Simulator.app, the device's next window in the same arrangement of
    /// screens opens at this center and scale. A window that closes during a
    /// restart saves nothing.
    private func saveWindowGeometry() {
        guard !closed, !isRestarting, let window else { return }
        preferences.setWindowGeometry(center: NSPoint(x: window.frame.midX, y: window.frame.midY),
                                      scale: WindowScale.usable(session.display.renderScale),
                                      forDevice: session.device.id, screens: Self.screenFrames)
    }
    private func disconnect() {
        guard !closed else { return }
        closed = true
        pluginLookUp?.cancel()
        pluginLookUp = nil
        keyboard.invalidate()
        fitting.invalidate()
        for observer in [screenParametersObserver, touchPressureObserver, touchIndicatorObserver,
                         keyboardSelectionObserver, audioRouteObserver].compactMap(\.self) {
            NotificationCenter.default.removeObserver(observer)
        }
        screenParametersObserver = nil
        touchPressureObserver = nil
        touchIndicatorObserver = nil
        keyboardSelectionObserver = nil
        audioRouteObserver = nil
        if let window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
        }
        customLocation?.close()
        closeExternalDisplayWindow()
        session.disconnect()
    }
    /// A controller released without closing its window, which
    /// `HostApplication` discards when another host appears before the window
    /// shows, disconnects without saving the window's geometry.
    isolated deinit { disconnect() }
}

/// Simulator.app's `DeviceWindow`, which lets a window whose bezel has top
/// padding extend past the screen and receives the presses on the bezel
/// that resize or move the window.
@MainActor
final class DeviceWindow: NSWindow {
    /// The top padding of the display's bezel at scale 1,
    /// `SimDeviceChrome.images.padding.height`; 0 without a bezel.
    var chromeTopPadding: CGFloat = 0
    /// The display's scale, which the padding scales with.
    var displayScale: () -> CGFloat = { 1 }
    /// Receives each mouse down, drag, and up that no view in the window
    /// handles, such as a press on the bezel, and returns whether it handled
    /// the event.
    var handleMouseEvent: (NSEvent) -> Bool = { _ in false }

    override func mouseDown(with event: NSEvent) {
        if !handleMouseEvent(event) { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if !handleMouseEvent(event) { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if !handleMouseEvent(event) { super.mouseUp(with: event) }
    }

    /// Like Simulator.app, while the bezel has top padding, the frame keeps
    /// its size and moves down only as far as the top of the bezel, below the
    /// padding, needs to stay below the top of the screen's visible frame.
    /// Otherwise AppKit constrains the frame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let target = screen ?? self.screen, chromeTopPadding > 0 else {
            return super.constrainFrameRect(frameRect, to: screen)
        }
        return WindowScale.frame(frameRect, constrainedBelow: target.visibleFrame,
                                 topInset: chromeTopPadding * displayScale())
    }

    /// The window's corner radius, which Simulator.app reads from the private
    /// `NSWindow._cornerRadius` for the lower corners of the title bar. Without
    /// that method, the radius macOS 26 gives a titled window with its toolbar
    /// style: 26 points unified, 20 compact, and 16 expanded.
    private var cornerRadius: CGFloat {
        let selector = NSSelectorFromString("_cornerRadius")
        if responds(to: selector) {
            typealias Getter = @convention(c) (NSWindow, Selector) -> CGFloat
            return unsafe unsafeBitCast(method(for: selector), to: Getter.self)(self, selector)
        }
        switch toolbarStyle {
        case .unified: return 26
        case .unifiedCompact: return 20
        default: return 16
        }
    }

    /// The view that holds the title bar and the toolbar, Simulator.app's
    /// `NSTitlebarContainerView`: the close button's ancestor among the
    /// subviews of the window's frame view. Nil while the title bar is in
    /// another window, as in full screen.
    private var titlebarContainer: NSView? {
        guard let frameView = contentView?.superview else { return nil }
        var view: NSView? = standardWindowButton(.closeButton)
        while let current = view, current.superview !== frameView { view = current.superview }
        return view
    }

    /// Rounds the lower corners of the title bar with the window's corner
    /// radius, so that the title bar's shape matches the window's top, or
    /// squares them, as Simulator.app's `DeviceWindow` does with the layer of
    /// its title bar container.
    func roundHeader(_ rounded: Bool) {
        guard let layer = titlebarContainer?.layer else { return }
        guard rounded else {
            layer.cornerRadius = 0
            return
        }
        layer.cornerRadius = cornerRadius
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.masksToBounds = true
    }
}

@MainActor
private final class DeviceContentView: NSView, DisplayContentView {
    let display: NSView
    var canImport: () -> Bool = { false }
    var importFiles: ([URL]) -> Void = { _ in }
    /// The space between the header and the display, which follows the bezel.
    var displayGap = WindowScale.displayGap(bezelPadding: nil) {
        didSet { needsLayout = true }
    }
    /// Whether the window has the display's size, as Simulator.app's
    /// geometry update gives it. The display then fills the window below the
    /// gap, as Simulator.app's constraints pin its display view, also where
    /// the integral frame leaves a fraction of a point. In full screen and
    /// after a manual resize, the display keeps its own size, centered below
    /// the gap.
    var isSizedToDisplay = false {
        didSet { needsLayout = true }
    }
    /// The title bar's height, which follows the toolbar's style: 52 points
    /// unified, 76 expanded, and 40 compact on macOS 26.
    var headerHeight: CGFloat {
        guard let window else { return 52 }
        return max(0, bounds.height - window.contentLayoutRect.height)
    }
    /// The window's height above the display: the header and the gap below it.
    var heightAboveDisplay: CGFloat { headerHeight + displayGap }
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
        NSSize(width: max(1, bounds.width), height: max(1, bounds.height - heightAboveDisplay))
    }

    override func layout() {
        super.layout()
        let available = NSRect(origin: .zero, size: availableDisplaySize)
        if isSizedToDisplay {
            display.frame = available
        } else {
            let intrinsic = display.intrinsicContentSize
            let size = intrinsic.width > 0 && intrinsic.height > 0 ? intrinsic : display.frame.size
            display.frame = NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                                   width: size.width, height: size.height)
        }
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

    /// The first of `name`, "name #2" through "name #99" that is free in
    /// `folder` and not reserved.
    static func unusedFile(in folder: URL, named name: String, isReserved: (URL) -> Bool = { _ in false }) throws -> URL {
        let base = (name as NSString).deletingPathExtension, suffix = (name as NSString).pathExtension
        for number in 1...99 {
            let candidate = folder.appendingPathComponent(number == 1 ? name : "\(base) #\(number).\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate.path), !isReserved(candidate) { return candidate }
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
