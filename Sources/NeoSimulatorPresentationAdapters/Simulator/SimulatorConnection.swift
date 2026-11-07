import ABIBridge
import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import NeoSimulatorNative
import ObjectiveC

@MainActor
package final class SimulatorConnection: SimulatorDisplay {
    package let view: NSView
    /// `SimDisplayView.digitizerView`.
    private let digitizerView: NSView?
    /// The display's user-interface plugin, once found.
    private var plugin: SimulatorUserInterfacePlugin?
    private let runtime: SimulatorPresentationRuntime
    private let chromeView: NSView?
    private let nativeCanvas: NativeDeviceCanvas?
    private var nativeScale: CGFloat = 1
    package var usesNativeCanvas: Bool { nativeCanvas != nil }
    package var nativePoseControls: NativeDevicePoseControls? { nativeCanvas?.poseControls }
    private let device: SimulatorDevice
    private let buttonTarget: UInt32
    private let connectedDisplayID: UInt32
    package var captureDisplayID: UInt32? {
        get throws { try nativeCanvas?.captureDisplayID ?? connectedDisplayID }
    }
    private var hidClient: WorkerOwned<AnyObject>?
    private var disconnected = false
    package var onPropertiesChange: (() -> Void)?
    private var screenEvents: NativeSwiftValue?
    private let screen: AnyObject
    /// The device's native keyboard once it is ready, which takes the Mac's keyboard instead of SimulatorKit's Indigo
    /// keyboard. The integrated screen's connection owns it; external and app-resizing displays share it.
    private let nativeKeyboard: SharedNativeKeyboard
    private var keyboard: NativeDeviceKeyboard? { nativeKeyboard.keyboard }
    private let ownsKeyboard: Bool
    private var keyboardResponder: NativeKeyboardResponder?
    private let simulatorKeyboard = SimulatorKeyboardInput()
    var hasPressedSimulatorKeys: Bool { simulatorKeyboard.hasPressedKeys }
    /// What the window last asked for, which input that becomes ready later takes up.
    private var keyboardRequested = false
    private var trackpadRequested = false
    /// The device's native trackpad, which takes the Mac trackpads' scrolling and pinches over the integrated screen
    /// instead of SimulatorKit's digitizer. Its guest services have no display of their own, so this connection alone has
    /// and owns it; external and app-resizing displays keep SimulatorKit's input.
    private var trackpad: NativeDeviceTrackpad?
    private var trackpadInput: NativeTrackpadInput?
    /// Native touches and buttons for the integrated screen. External and resized-app displays
    /// keep SimulatorKit input; native canvases send their own touches and use only these buttons.
    private var screenInput: NativeDeviceScreenInput?
    private var digitizerTouches: NativeDigitizerTouches?
    /// The buttons sent down through SimulatorKit and not yet up, whose releases must also go through it.
    private var simulatorKitButtonsDown: Set<HIDInput> = []
    /// Connects this display's native input, which the display does not wait for.
    package var inputActivation: NativeInputActivation?
    private let pasteboardRoute: SimulatorPasteboardRoute
    /// What this connection's services ask CoreDevice through, which ends with the connection. A display that shares a
    /// device's connection has none of its own.
    private let deviceRecord: CoreDeviceSimulatorRecord?
    private let displays: SimulatorDisplaySet

    /// The display starts with SimulatorKit's input, which the guest takes until `activateNativeInput` gives it native
    /// input. `nativeKeyboard` is the one the device's displays share; one made here belongs to this display.
    package init(device: SimulatorDevice, screen: (identifier: UInt32, object: AnyObject), runtime: SimulatorPresentationRuntime,
         displays: SimulatorDisplaySet, pasteboardRoute: SimulatorPasteboardRoute,
         nativeCanvas: NativeDeviceCanvas? = nil, nativeKeyboard: SharedNativeKeyboard? = nil,
         deviceRecord: CoreDeviceSimulatorRecord? = nil) async throws {
        self.deviceRecord = deviceRecord
        self.nativeCanvas = nativeCanvas
        self.device = device
        self.runtime = runtime
        self.screen = screen.object
        self.displays = displays
        self.pasteboardRoute = pasteboardRoute
        self.nativeKeyboard = nativeKeyboard ?? SharedNativeKeyboard()
        ownsKeyboard = nativeKeyboard == nil
        connectedDisplayID = screen.identifier
        let display = runtime.display
        buttonTarget = try unsafe display.buttonTarget.unsafeInvoke(on: screen.object)
        hidClient = try await runtime.input.connect(to: device)
        if let nativeCanvas {
            view = nativeCanvas.view
            view.frame.size = nativeCanvas.naturalSize
            digitizerView = nil
            chromeView = nil
            screenInput = nativeCanvas.buttons
            nativeCanvas.onSizeChange = { [weak self] in self?.onPropertiesChange?() }
            displays.register(self)
            return
        }
        guard let view = try unsafe display.createDisplay.unsafeInvoke(
            on: display.factoryClass as AnyObject, device.handle.object, screen.identifier)
        else {
            throw SimulatorError.unavailable("SimulatorKit returned no display")
        }
        self.view = view
        do {
            try await runtime.validateLoadedImages()
            digitizerView = try unsafe display.digitizerView.unsafeInvoke(on: view)
            chromeView = try unsafe display.chromeView.unsafeInvoke(on: view)
            try Task.checkCancellation()
        } catch {
            try? unsafe display.disconnect.unsafeInvoke(on: view, NativeSwiftClosure {})
            throw error
        }
        let handler = try SimulatorDisplayInterface.ScreenEventHandler { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onPropertiesChange?() }
        }
        screenEvents = try unsafe display.registerScreenEvents.unsafeInvoke(
            on: screen.object, display.screenPropertyEvents, .main, handler)
        // SimulatorKit connects keyboard input on every display and sends each modifier
        // change to all of them; the window controller enables it only while the window is key.
        // A native keyboard replaces it, which keeps Indigo from reattaching its own keyboard.
        setSimulatorKitKeyboardEnabled(false)
        displays.register(self)
        self.nativeKeyboard.add(self)
    }

    /// Hands over after SimulatorKit's held inputs finish, activating native touches first.
    /// Native keyboard or trackpad input makes the guest reject SimulatorKit touches and buttons.
    /// If the digitizer cannot hand over touches, all input stays with SimulatorKit.
    package func activateNativeInput(_ services: NativeInputServices) async throws {
        guard let digitizerView else { return }
        var touches: NativeDigitizerTouches?
        if let route = services.touchRoute {
            touches = try await NativeDigitizerTouches(digitizer: digitizerView, interface: route.interface) {
                [weak self, input = route.input] touch in
                // A mouse press takes over from any trackpad gesture before starting its own touch.
                if touch.phase == .began { self?.trackpad?.endGestures() }
                input.sendTouch(at: touch.point, secondPoint: touch.secondPoint, phase: touch.phase, edge: touch.edge)
            }
        }
        while NSEvent.pressedMouseButtons != 0 || !simulatorKitButtonsDown.isEmpty || nativeKeyboard.hasPressedSimulatorKeys {
            try await Task.sleep(for: .milliseconds(50))
        }
        // Nothing suspends from here on, so SimulatorKit cannot start a key, touch or button across the handoff.
        try Task.checkCancellation()
        guard !disconnected else { throw CancellationError() }
        var input: NativeTrackpadInput?
        if let trackpad = services.trackpad {
            let framebuffer = try unsafe runtime.display.renderableView.unsafeInvoke(on: view)
            input = NativeTrackpadInput(display: view, framebuffer: framebuffer, send: trackpad.handle,
                                        endGestures: trackpad.endGestures)
        }
        try touches?.install()
        digitizerTouches = touches
        screenInput = services.touchRoute?.input
        trackpad = services.trackpad
        trackpadInput = input
        input?.isEnabled = trackpadRequested
        if let keyboard = services.keyboard { nativeKeyboard.activate(keyboard) }
    }

    /// Takes up the device's native keyboard, on each display that shares it.
    func keyboardActivated(_ keyboard: NativeDeviceKeyboard) {
        guard nativeCanvas == nil, !disconnected else { return }
        simulatorKeyboard.stop()
        setSimulatorKitKeyboardEnabled(false)
        keyboardResponder = NativeKeyboardResponder { [weak self] event in
            guard let self, !disconnected, keyboard.isEnabled(for: self) else { return false }
            keyboard.handle(event)
            return true
        }
        setKeyboardEnabled(keyboardRequested)
    }

    package func connectAppDisplay(uniqueID: String) async throws -> any DeviceSessionDisplay {
        // Device Hub waits up to 30 seconds for the same uniqueId in this device's
        // screen adapter. CoreDevice displayId and SimulatorKit screenID differ.
        for _ in 0..<120 {
            try Task.checkCancellation()
            guard isBooted else { throw SimulatorError.unavailable("The simulator disconnected while preparing app resizing.") }
            if let screen = try runtime.display.appScreen(uniqueID: uniqueID, of: device) {
                let connection = try await SimulatorConnection(device: device, screen: screen, runtime: runtime, displays: displays,
                                                               pasteboardRoute: pasteboardRoute, nativeKeyboard: nativeKeyboard)
                connection.setChromeVisible(false)
                return connection
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SimulatorError.unavailable("Timed out waiting for the app resizing screen.")
    }

    package var isBooted: Bool { !disconnected && device.state == 3 }

    package var inputView: NSView { nativeCanvas?.inputView ?? plugin?.overlayView ?? digitizerView ?? view }

    package var deviceFrame: NSRect {
        guard nativeCanvas == nil else { return view.bounds }
        if chromePadding != nil {
            // SimDisplayView also reserves space for hardware buttons outside the device artwork.
            guard let artwork = chromeView?.subviews.first(where: {
                $0.className == "SimulatorKit.SimDisplayChromeRenderView"
            }) else { return view.bounds }
            return view.convert(artwork.bounds, from: artwork)
        }
        return framebufferFrame
    }

    package var framebufferFrame: NSRect {
        guard nativeCanvas == nil else { return view.bounds }
        return read("measure the displayed screen", otherwise: view.bounds) {
            let framebuffer = try unsafe runtime.display.renderableView.unsafeInvoke(on: view)
            return view.convert(framebuffer.bounds, from: framebuffer)
        }
    }

    package func userInterfacePlugin() async throws -> SimulatorUserInterfacePlugin? {
        guard nativeCanvas == nil else { return nil }
        if let plugin { return plugin }
        let display = runtime.display
        guard !disconnected, let object = object_getIvar(view, display.userInterfacePlugin) as AnyObject? else {
            return nil
        }
        // The plugin's bundle and what it loaded are checked as the display's
        // own frameworks are.
        try await runtime.validateLoadedImages()
        let plugin = SimulatorUserInterfacePlugin(
            overlayView: try display.pluginMessages.send("overlayView", to: object, as: NSView?.self),
            toolbar: try display.pluginMessages.send("toolbar", to: object, as: NSToolbar?.self))
        self.plugin = plugin
        return plugin
    }

    /// The messages that read the backlight, by protocol.
    package static let backlightSelectors = [("SimScreenProperties", ["backlight"]), ("SimScreenBacklight", ["state"])]

    // Read properties directly: SimDisplayView.backlightState lags until its change callback.
    package var backlightState: Int32? {
        guard !disconnected else { return nil }
        let display = runtime.display
        return read("read the backlight", otherwise: nil) {
            let properties = try unsafe display.screenProperties.unsafeInvoke(on: screen)
            return try display.screenMessages.send("backlight", to: properties, as: AnyObject?.self)
                .map { try display.screenMessages.send("state", to: $0, as: Int32.self) }
        }
    }

    package func announceRecording(started: Bool) {
        let name = started ? "SimulatorVideoRecordingStartedNotification" : "SimulatorVideoRecordingStoppedNotification"
        NotificationCenter.default.post(name: Notification.Name(name), object: nil,
                                        userInfo: [name + "DeviceUserInfoKey": device.handle.object])
    }

    package var renderScale: CGFloat {
        if nativeCanvas != nil { return nativeScale }
        return read("read the display scale", otherwise: 0) { try unsafe runtime.display.renderScale.unsafeInvoke(on: view) }
    }

    package func setRenderScale(_ scale: CGFloat) {
        if let nativeCanvas { nativeScale = scale; nativeCanvas.setZoom(scale); return }
        perform("scale the display") { try unsafe runtime.display.setRenderScale.unsafeInvoke(on: view, scale) }
        view.invalidateIntrinsicContentSize()
    }

    package func setCanvasMagnification(_ magnification: CGFloat?) { nativeCanvas?.setMagnification(magnification) }

    package func size(for scale: CGFloat) -> NSSize {
        if let nativeCanvas { return NSSize(width: nativeCanvas.naturalSize.width * scale, height: nativeCanvas.naturalSize.height * scale) }
        return read("measure the display", otherwise: .zero) { try unsafe runtime.display.sizeForScale.unsafeInvoke(on: view, scale) }
    }

    package func scale(for size: NSSize) -> CGFloat {
        if let nativeCanvas { return min(size.width / nativeCanvas.naturalSize.width, size.height / nativeCanvas.naturalSize.height) }
        return read("measure the display", otherwise: 0) { try unsafe runtime.display.scaleForSize.unsafeInvoke(on: view, size) }
    }

    package var screenScale: CGFloat? {
        read("read the screen scale", otherwise: nil) { try unsafe runtime.display.screenScale.unsafeInvoke(on: screen) }
    }

    package var displayClass: UInt16? {
        read("read the display class", otherwise: nil) { try unsafe runtime.display.displayClass.unsafeInvoke(on: screen) }
    }

    package var chromePadding: NSSize? {
        guard let chromeView else { return nil }
        let display = runtime.display
        return read("read the device bezel", otherwise: nil) {
            guard let chrome = try unsafe display.chrome.unsafeInvoke(on: chromeView) else { return nil }
            return try unsafe display.chromeImagesPadding.unsafeInvoke(on: display.chromeImages.unsafeInvoke(on: chrome))
        }
    }

    package func setShowsResizeCursors(_ shows: Bool) {
        guard nativeCanvas == nil else { return }
        perform("show resize cursors") { try unsafe runtime.display.showResizeCursors.unsafeInvoke(on: view, shows) }
    }

    package var guestInterfaceAngle: Double? {
        guard nativeCanvas == nil, !disconnected,
              let properties = try? unsafe runtime.display.screenProperties.unsafeInvoke(on: screen),
              let orientation = try? unsafe ABIRuntime.shared.object(properties)
                .resolveAndWait(.objc(.method("uiOrientation", as: (() -> UInt32).self))).unsafeInvoke()
        else { return nil }
        return SimScreenUIOrientation.displayAngle(orientation)
    }

    package func message(for input: HIDInput, _ state: HIDState) throws -> HIDMessage {
        try runtime.input.message(input, state, target: buttonTarget)
    }

    package func send(_ message: HIDMessage, completion: (@MainActor (Error?) -> Void)?) throws {
        if let usage = message.input.nativeButtonUsage {
            let state: RemoteDeviceButtonState = message.state == .down ? .down : .up
            if let screenInput, !disconnected {
                try screenInput.sendButton(usagePage: usage.page, usage: usage.usage, state: state) { completion?($0) }
                return
            }
        }
        guard let hidClient else { throw SimulatorError.operation("Simulator input is disconnected") }
        try runtime.input.send(message, client: hidClient.value, completion: completion)
        if message.state == .down { simulatorKitButtonsDown.insert(message.input) } else { simulatorKitButtonsDown.remove(message.input) }
    }

    package func message(for touch: TVRemoteTouch) throws -> HIDMessage {
        HIDMessage(input: .tvRemoteTouch, state: touch.phase == .ended ? .up : .down,
                   pointer: try runtime.input.message(for: touch))
    }

    package func send(_ gesture: WatchGesture, completion: @escaping @MainActor (Error?) -> Void) throws {
        guard let hidClient else { throw SimulatorError.operation("Simulator input is disconnected") }
        try runtime.input.send(gesture, client: hidClient.value, completion: completion)
    }

    package func toggleAppearance() async throws { try await device.toggleAppearance() }
    package func postNotification(_ name: String) async throws { try await device.postNotification(name) }
    package func sendNotificationState(_ name: String, to state: UInt64) async throws {
        try await device.sendNotificationState(name, to: state)
    }
    package func updateNotificationState(_ name: String, _ change: @escaping @Sendable (UInt64) -> UInt64) async throws {
        try await device.updateNotificationState(name, change)
    }
    package func updateContentSizeCategory(_ change: @escaping @Sendable (Int) throws -> Int?) async throws {
        try await device.updateContentSizeCategory(change)
    }
    package func updateIncreaseContrast(_ change: @escaping @Sendable (Int) throws -> Bool) async throws {
        try await device.updateIncreaseContrast(change)
    }
    package func triggerCloudSync() async throws { try await device.triggerCloudSync() }
    package func guestState(notifications: [String], debugOptions: [CADebugOption]) async throws -> GuestStateReading {
        try await device.guestState(notifications: notifications, debugOptions: debugOptions.map(\.rawValue))
    }
    package func logDirectory() throws -> URL { try device.logDirectory() }
    package func memoryWarningFile() throws -> URL { try device.memoryWarningFile() }
    package func toggleCADebugOption(_ option: CADebugOption) async throws -> CADebugOptionChange {
        try await device.toggleCADebugOption(option.rawValue, title: option.title)
    }
    package func locationScenarios() async throws -> [LocationScenario] { try await device.locationScenarios() }
    package func clearSimulatedLocation() async throws { try await device.clearSimulatedLocation() }
    package func setLocation(latitude: Double, longitude: Double) async throws {
        try await device.setLocation(latitude: latitude, longitude: longitude)
    }
    package func setLocationScenario(_ name: String) async throws { try await device.setLocationScenario(name) }
    package func setHardwareKeyboardConnected(_ connected: Bool) async throws {
        var failure: (any Error)?
        do { try await device.setHardwareKeyboardEnabled(connected, keyboardType: runtime.input.currentKeyboardType()) }
        catch { failure = error }
        // The guest also counts native keyboard services as connected hardware keyboards; input recreates them.
        if !connected, let keyboard {
            do { try await keyboard.removeServices() }
            catch {
                failure = failure.map { SimulatorError.operation([$0.localizedDescription, error.localizedDescription].joined(separator: "\n")) }
                    ?? error
            }
        }
        if let failure { throw failure }
    }
    package func setKeyboardLanguage(_ language: String) async throws { try await device.setKeyboardLanguage(language) }
    package var hostPasteboardChangeCount: Int { NSPasteboard.general.changeCount }
    package func connectPasteboard(sync: PasteboardSync?,
                           events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) async throws -> any SimulatorPasteboard {
        if let transport = try await pasteboardRoute.transport() {
            return NativePasteboardConnection(transport: transport, managing: .general, sync: sync, events: events)
        }
        return try await runtime.pasteboard.connect(to: device, managing: .general, events: events)
    }
    package func connectAudioRoutes(changed: @escaping @MainActor (AudioRouteChange) -> Void) async throws -> any SimulatorAudioRoutes {
        try await runtime.audio.connect(to: device, changed: changed)
    }
    package func registerForExternalScreen(
        changed: @escaping @MainActor () -> Void,
        found: @escaping @MainActor (Result<any SimulatorExternalScreen, any Error>) -> Void
    ) throws -> AnyObject? {
        try runtime.display.registerForExternalScreens(of: device) { [device, runtime, displays, pasteboardRoute, nativeKeyboard] screen in
            found(Result {
                try SimulatorExternalScreenConnection(device: device, screen: try screen.get(), runtime: runtime, displays: displays,
                                                      pasteboardRoute: pasteboardRoute, nativeKeyboard: nativeKeyboard, changed: changed)
            })
        }
    }
    package func setChromeVisible(_ visible: Bool) {
        if let nativeCanvas { nativeCanvas.setChromeVisible(visible); return }
        guard let chromeView else { return }
        let display = runtime.display
        perform("show device chrome") {
            try unsafe display.showChrome.unsafeInvoke(on: view, visible)
            if visible {
                // Preserve the device artwork when its window loses keyboard focus.
                let state = try display.chromeState.makeEnumCase(named: "active")
                try unsafe display.setChromeState.unsafeInvoke(on: chromeView, state)
            }
        }
        view.invalidateIntrinsicContentSize()
    }
    package func setKeyboardEnabled(_ enabled: Bool) {
        keyboardRequested = enabled
        guard nativeCanvas == nil, !disconnected else { return }
        if !enabled { simulatorKeyboard.stop() }
        // SimulatorKit's digitizer passes the keys it does not handle to the native keyboard. A device UI plugin's
        // overlay takes the input instead, so SimulatorKit's keyboard remains with that display.
        if enabled, let keyboard, let keyboardResponder, let digitizerView, inputView === digitizerView {
            keyboardResponder.attach(after: digitizerView)
            keyboard.setEnabled(true, for: self)
        } else if !enabled, let keyboard, keyboard.isEnabled(for: self) {
            keyboard.setEnabled(false, for: self)
        } else {
            if enabled { simulatorKeyboard.start(for: inputView) }
            setSimulatorKitKeyboardEnabled(enabled)
        }
    }
    package func sendKeyboardEvent(_ event: NSEvent) {
        simulatorKeyboard.send(event, to: inputView)
    }
    private func setSimulatorKitKeyboardEnabled(_ enabled: Bool) {
        guard nativeCanvas == nil, !disconnected, let keyboard = object_getIvar(view, runtime.display.keyboardDelegate) else { return }
        perform("enable keyboard input") {
            try unsafe runtime.display.setKeyboardEnabled.unsafeInvoke(on: keyboard as AnyObject, enabled)
        }
    }
    package func setTrackpadEnabled(_ enabled: Bool) {
        trackpadRequested = enabled
        trackpadInput?.isEnabled = enabled && !disconnected
    }
    package func setSupportsScrolling(_ supports: Bool) {
        guard !disconnected, let digitizerView else { return }
        perform("enable scrolling") {
            try unsafe runtime.display.setSupportsScrolling.unsafeInvoke(on: digitizerView, supports)
        }
    }
    private var edgeSwipeUpdates: Task<Void, Never>?

    package func setWantsEdgeSwipes(_ wants: Bool) {
        guard nativeCanvas == nil, !disconnected else { return }
        let previous = edgeSwipeUpdates
        edgeSwipeUpdates = Task { [weak self] in
            await previous?.value
            guard let self, !disconnected else { return }
            do {
                try await device.sendNotificationState("com.apple.UIKit.SimulatorWantsEdgeSwipes", to: wants ? 1 : 0)
            } catch {
                hostLog("Could not tell the device whether edge swipes start on the bezel: \(error.localizedDescription)")
            }
        }
    }
    package func setSupportsTouchPressure(_ supports: Bool) {
        guard !disconnected, let digitizerView else { return }
        perform("enable touch pressure") {
            try unsafe runtime.display.setSupportsTouchPressure.unsafeInvoke(on: digitizerView, supports)
        }
    }
    package func setUsesTrackpadForce(_ uses: Bool) {
        guard !disconnected, let digitizerView else { return }
        perform("use the trackpad's force") {
            try unsafe runtime.display.setUsesTrackpadForce.unsafeInvoke(on: digitizerView, uses)
        }
    }
    package func setSimulatedTouchMode(_ mode: SimulatedTouchMode) {
        guard !disconnected, let digitizerView else { return }
        perform("set the touch pressure") {
            try unsafe runtime.display.setSimulatedTouchMode.unsafeInvoke(on: digitizerView, mode.rawValue)
        }
    }
    package func setTouchIndicator(_ indicator: TouchIndicator, shown: Bool) {
        guard !disconnected, let digitizerView else { return }
        let display = runtime.display
        perform("show touch indicators") {
            let options = try unsafe display.drawOptionRawValue.unsafeInvoke(on: display.drawOptions.unsafeInvoke(on: digitizerView))
            let option = display.drawOption(for: indicator)
            try unsafe display.setDrawOptions.unsafeInvoke(
                on: digitizerView, display.makeDrawOption.unsafeInvoke(shown ? options | option : options & ~option))
        }
    }
    package func setRotation(degrees: Double) {
        guard nativeCanvas == nil else { return }
        perform("rotate the display") {
            try unsafe runtime.display.rotation.unsafeInvoke(on: view, Measurement(value: degrees, unit: .degrees))
        }
        view.invalidateIntrinsicContentSize()
    }
    package func beginResize() { guard nativeCanvas == nil else { return }; perform("begin resizing") { try unsafe runtime.display.beginResize.unsafeInvoke(on: view) } }
    package func endResize() { guard nativeCanvas == nil else { return }; perform("end resizing") { try unsafe runtime.display.endResize.unsafeInvoke(on: view) } }
    package func disconnect() {
        guard !disconnected else { return }
        simulatorKeyboard.stop()
        disconnected = true
        inputActivation?.cancel()
        deviceRecord?.stop()
        // The digitizer gets its own delegate back before SimulatorKit disconnects the display, so no more touches reach
        // the native touchscreen. A failed restore leaves the replacement with this connection, which `stop()` retries.
        if let digitizerTouches {
            do { try digitizerTouches.restore(); self.digitizerTouches = nil } catch {
                hostLog("Could not give the digitizer its own delegate back: \(error.localizedDescription)")
            }
        }
        if let nativeCanvas { nativeCanvas.onSizeChange = nil; nativeCanvas.disconnect() }
        else {
            perform("disconnect the display") {
                try unsafe runtime.display.disconnect.unsafeInvoke(on: view, NativeSwiftClosure {})
            }
        }
        // Releasing the registration ends the screen events.
        screenEvents = nil
        onPropertiesChange = nil
        hidClient = nil
        keyboardResponder?.detach()
        keyboard?.setEnabled(false, for: self)
        trackpadInput?.isEnabled = false
    }
    package func stop() async throws {
        disconnect()
        var failures: [String] = []
        // Input that is still connecting has sent the guest nothing. The activation stops what no display took up, also
        // what answers after this returned, and this reports what it has not finished.
        if let inputActivation {
            if await !inputActivation.ends(before: ContinuousClock.now + HostPreferences.terminationLimit) {
                failures.append("The device's native input had not finished connecting.")
            }
            do { try await inputActivation.stopUnactivated() }
            catch { failures.append("Could not stop the native input that no display took up: \(error.localizedDescription)") }
        }
        if let digitizerTouches {
            do { try digitizerTouches.restore(); self.digitizerTouches = nil }
            catch { failures.append("Could not give the digitizer its own delegate back: \(error.localizedDescription)") }
        }
        if ownsKeyboard, let keyboard {
            do { try await keyboard.stop() }
            catch { failures.append("Could not remove the native keyboard services: \(error.localizedDescription)") }
        }
        if let trackpad {
            do { try await trackpad.stop() }
            catch { failures.append("Could not remove the native trackpad services: \(error.localizedDescription)") }
        }
        if let screenInput {
            do { try await screenInput.stop() }
            catch { failures.append("Could not release the native touchscreen and buttons: \(error.localizedDescription)") }
        }
        guard !failures.isEmpty else { return }
        let failure = SimulatorError.operation(failures.joined(separator: "\n"))
        // Only a shut-down guest (SimDeviceState 1) no longer holds the input. Shutting down (4) and a state that
        // cannot be read keep the failure, and the services for the next call.
        guard (try? await device.currentState()) == 1 else { throw failure }
        hostLog(failure.localizedDescription)
    }
    isolated deinit { disconnect() }

    // These members were prepared during startup; a failure here means
    // SimulatorKit rejected the value, which the display cannot recover from.
    private func perform(_ operation: String, _ body: () throws -> Void) {
        read(operation, otherwise: (), body)
    }

    private func read<Value>(_ operation: String, otherwise fallback: Value, _ body: () throws -> Value) -> Value {
        do { return try body() } catch {
            hostLog("Could not \(operation): \(error.localizedDescription)")
            return fallback
        }
    }
}
