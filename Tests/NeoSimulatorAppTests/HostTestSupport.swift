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

/// Waits for rendered state without relying on XCTest's run-loop predicate timer.
@MainActor
func wait(timeout: Duration = .seconds(2), sourceLocation: SourceLocation = #_sourceLocation,
          until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        try #require(ContinuousClock.now < deadline, "The expected state did not arrive within \(timeout).",
                     sourceLocation: sourceLocation)
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
func loadTestRuntime() async throws -> SimulatorPresentationRuntime {
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
    return try await SimulatorPresentationRuntime.load(xcodeURL: xcode)
}

@MainActor
func noOtherHostIsDisplaying() -> Bool { HostConflictMonitor().conflictingHostName == nil }

@MainActor
final class TestAppResizeTransport: AppResizeTransport {
    let lease = TestAppResizeLease()
    let eligibilityUpdates = AsyncThrowingStream<AppResizeEligibility, any Error>.makeStream()
    var holdsStart = false
    var startContinuation: CheckedContinuation<any AppResizeSession, Never>?
    func eligibility() async throws -> AsyncThrowingStream<AppResizeEligibility, any Error> {
        eligibilityUpdates.continuation.yield(.eligible)
        return eligibilityUpdates.stream
    }
    func start(size: CGSize, cornerRadius: CGFloat) async throws -> any AppResizeSession {
        if holdsStart { return await withCheckedContinuation { startContinuation = $0 } }
        return lease
    }
    func completeStart() { startContinuation?.resume(returning: lease); startContinuation = nil }
}

@MainActor
final class TestAppResizeLease: AppResizeSession {
    let displayUniqueID = "dedicated-app-display"
    var geometry = AppResizeGeometry(minimumSize: CGSize(width: 200, height: 200), maximumSize: CGSize(width: 1000, height: 1000),
        preferredSize: CGSize(width: 500, height: 600), resolvedSize: CGSize(width: 500, height: 600), cornerRadius: 0)
    let geometryUpdates = AsyncThrowingStream<AppResizeGeometry, any Error>.makeStream()
    let invalidation = AsyncStream<Void>.makeStream()
    var invalidations = 0
    var adjustedSizes: [CGSize] = []
    var adjustmentError: (any Error)?
    var holdsAdjustment = false
    var adjustmentContinuation: CheckedContinuation<Void, Never>?
    func completeAdjustment() { adjustmentContinuation?.resume(); adjustmentContinuation = nil }
    func updates() throws -> AsyncThrowingStream<AppResizeGeometry, any Error> { geometryUpdates.stream }
    func adjust(size: CGSize, cornerRadius: CGFloat) async throws {
        if let adjustmentError { throw adjustmentError }
        adjustedSizes.append(size)
        if holdsAdjustment { await withCheckedContinuation { adjustmentContinuation = $0 } }
    }
    func awaitInvalidation() async throws { for await _ in invalidation.stream { return } }
    func invalidate() throws {
        guard invalidations == 0 else { return }
        invalidations += 1
        invalidation.continuation.finish()
        geometryUpdates.continuation.finish()
    }
}

@MainActor
final class ChangeLog {
    var onMainThread: [Bool] = []
}

/// Entries use "watch-type watch-runtime phone-type phone-runtime".
@MainActor
final class PairingChecks {
    var entries: [String] = []
}

struct ButtonFace: Equatable {
    var symbol: String?
    var imageDescription: String?
    var toolTip: String?
    var label: String

    static let home = ButtonFace(symbol: "house", imageDescription: "Home", toolTip: "Home", label: "Home")
    static let saveScreen = ButtonFace(symbol: "camera.on.rectangle", imageDescription: "Save Screen",
                                       toolTip: "Save Screen", label: "Save Screen")
    static let recordScreen = ButtonFace(symbol: "record.circle", imageDescription: "Start Recording",
                                         toolTip: "Record Screen", label: "Save Screen")
    static let stopRecording = ButtonFace(symbol: "stop.circle", imageDescription: "Stop Recording",
                                          toolTip: "Stop Recording", label: "Save Screen")
    static let rotate = ButtonFace(symbol: "rotate.right", imageDescription: "Rotate Right", toolTip: "Rotate", label: "Rotate")
    /// As in Simulator.app, the image has the symbol's own description.
    static let rotateLeft = ButtonFace(symbol: "rotate.left",
                                       imageDescription: NSImage(systemSymbolName: "rotate.left", accessibilityDescription: nil)?
                                           .accessibilityDescription,
                                       toolTip: "Rotate", label: "Rotate")
    static let captureKeyboard = ButtonFace(symbol: "keyboard", imageDescription: "Capture Keyboard",
        toolTip: "Capture Keyboard — hold Escape for one second to release.", label: "Capture Keyboard")
    static let normal = [captureKeyboard, home, saveScreen, rotate]
    static let optionAlternates = [captureKeyboard, home, recordScreen, rotateLeft]

    @MainActor
    init(_ item: NSToolbarItem) {
        let image = item.image?.tiffRepresentation
        symbol = ["keyboard", "house", "camera.on.rectangle", "record.circle", "stop.circle", "rotate.right", "rotate.left"].first {
            image != nil && NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.tiffRepresentation == image
        }
        imageDescription = item.image?.accessibilityDescription
        toolTip = item.toolTip
        label = item.label
    }

    init(symbol: String?, imageDescription: String?, toolTip: String?, label: String) {
        (self.symbol, self.imageDescription, self.toolTip, self.label) = (symbol, imageDescription, toolTip, label)
    }
}

/// Sends AppKit tracking and modifier events while exposing the held keys.
@MainActor
final class ToolbarPointer {
    let area: NSTrackingArea
    private let window: NSWindow
    private let toolbar: NSToolbar
    private var keys: NSEvent.ModifierFlags = []

    init(_ controller: DeviceWindowController) throws {
        window = try #require(controller.window)
        toolbar = try #require(window.toolbar)
        let owner = try #require(toolbar.delegate as? DeviceToolbar)
        let view = try #require(toolbar.value(forKey: "_toolbarView") as? NSView)
        area = try #require(view.trackingAreas.first { $0.owner as AnyObject === owner })
        owner.modifierFlags = { [unowned self] in self.keys }
    }

    func enter() { report(.mouseEntered, "mouseEntered:") }
    func exit() { report(.mouseExited, "mouseExited:") }

    private func report(_ type: NSEvent.EventType, _ selector: String) {
        let event = NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: keys, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           trackingNumber: 0, userData: nil)
        _ = (area.owner as AnyObject).perform(NSSelectorFromString(selector), with: event)
    }

    func hold(_ keys: NSEvent.ModifierFlags) {
        self.keys = keys
        if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: keys,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58) {
            NSApp.sendEvent(event)
        }
    }

    /// Changes held keys without sending this app a modifier event.
    func holdInAnotherApp(_ keys: NSEvent.ModifierFlags) { self.keys = keys }

    func item(_ id: DeviceCommand.ID) throws -> NSToolbarItem {
        try #require(toolbar.items.first { $0.itemIdentifier.rawValue == id.rawValue })
    }

    var faces: [ButtonFace] {
        toolbar.items.filter { DeviceCommand.ID(rawValue: $0.itemIdentifier.rawValue) != nil }.map(ButtonFace.init)
    }

    func click(_ id: DeviceCommand.ID) throws -> Bool {
        let item = try item(id)
        return NSApp.sendAction(try #require(item.action), to: item.target, from: item)
    }
}

final class MemoryPreferences: PreferenceStore {
    var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

/// Isolates keys in the registration domain, preserving UserDefaults conversions without disk writes.
final class RegisteredDefaults: PreferenceStore {
    private let prefix = "NeoSimulatorTests.\(UUID().uuidString)."
    func object(forKey defaultName: String) -> Any? { UserDefaults.standard.object(forKey: prefix + defaultName) }
    func bool(forKey defaultName: String) -> Bool { UserDefaults.standard.bool(forKey: prefix + defaultName) }
    /// Registration cannot remove a value, so nil leaves the existing key unchanged.
    func set(_ value: Any?, forKey defaultName: String) {
        if let value { UserDefaults.standard.register(defaults: [prefix + defaultName: value]) }
    }
}

@MainActor
final class InputView: NSView {
    var keyDowns: [NSEvent] = []
    var keyUps: [NSEvent] = []
    var modifiers: [NSEvent] = []
    var presses: [NSEvent] = []
    /// SimulatorKit passes bezel presses up the responder chain after they leave the screen.
    var passesOnPresses = false
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keyDowns.append(event) }
    override func keyUp(with event: NSEvent) { keyUps.append(event) }
    override func flagsChanged(with event: NSEvent) { modifiers.append(event) }
    override func mouseDown(with event: NSEvent) {
        presses.append(event)
        if passesOnPresses { super.mouseDown(with: event) }
    }
}

/// Models key-window state without showing or activating a window on the WindowServer.
@MainActor
final class KeyPresentationWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// A drag on a private pasteboard, delivered without a WindowServer drag session.
@MainActor
final class TestDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingFormation = NSDraggingFormation.default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any?
    var draggingSequenceNumber: Int { 0 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(_ urls: [URL]) {
        super.init()
        draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    init(item: any NSPasteboardWriting, source: Any) {
        draggingSource = source
        super.init()
        draggingPasteboard.writeObjects([item])
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

@MainActor
final class TestKeyboardEventTap: KeyboardEventTap {
    private var receive: (@MainActor (CGEventType, CGEvent) -> Bool)?
    var starts = 0
    var stops = 0
    var startError: (any Error)?

    func start(receive: @escaping @MainActor (CGEventType, CGEvent) -> Bool) throws {
        if let startError { throw startError }
        starts += 1
        self.receive = receive
    }

    func stop() { stops += 1; receive = nil }

    func key(_ type: CGEventType, code: UInt16, flags: CGEventFlags = []) throws -> Bool {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type != .keyUp))
        if type == .flagsChanged { event.type = type }
        event.flags = flags
        return receive?(type, event) ?? false
    }
}

@MainActor
final class TestPluginToolbarDelegate: NSObject, NSToolbarDelegate {
    static let itemIdentifier = NSToolbarItem.Identifier("PluginControl")
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        NSToolbarItem(itemIdentifier: identifier)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.itemIdentifier]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.itemIdentifier]
    }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.itemIdentifier] }
}

/// Models menu handling by Apple Vision Pro's XROS.VirtualHMDInputView overlay.
@MainActor
final class PluginOverlay: NSView, NSMenuItemValidation {
    var actions: [String] = []
    private var showsGazeTarget = false
    override var acceptsFirstResponder: Bool { true }
    @objc func recenterAllOpenApps(_ sender: Any?) { actions.append("recenterAllOpenApps:") }
    @objc func viewportModeChangedToOrbit(_ sender: Any?) { actions.append("viewportModeChangedToOrbit:") }
    @objc func setImmersionTo75(_ sender: Any?) { actions.append("setImmersionTo75:") }
    @objc func configureSimulatedFaceTimeSession1x2(_ sender: Any?) {
        actions.append("configureSimulatedFaceTimeSession1x2:")
    }
    @objc func toggleShowGazeTarget(_ sender: NSMenuItem) {
        actions.append("toggleShowGazeTarget:")
        showsGazeTarget.toggle()
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleShowGazeTarget(_:)) { item.state = showsGazeTarget ? .on : .off }
        return true
    }
}

/// Consumes bezel presses like SimulatorKit's SimChromeButton.
@MainActor
final class TestButton: NSView {
    var presses: [NSEvent] = []
    override func mouseDown(with event: NSEvent) { presses.append(event) }
}

@MainActor
final class RefusingResponder: NSResponder {
    override func resignFirstResponder() -> Bool { false }
}

/// Avoids writing CoreSimulator defaults; even a scratch suite leaves a plist behind.
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

enum AppliedLocation: Equatable {
    case cleared, coordinate(Double, Double), scenario(String)
}

/// Mirrors SimDisplayView's intrinsic sizing.
@MainActor
final class TestDisplayView: NSView {
    var displaySize: () -> NSSize = { .zero }
    var onBackingPropertiesChange: () -> Void = {}
    override var intrinsicContentSize: NSSize { displaySize() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onBackingPropertiesChange()
    }
}

/// The test displays, which each test window finds its sessions' displays in.
@MainActor let testDisplays = SimulatorDisplaySet()

@MainActor
final class TestDisplay: SimulatorDisplay {
    var usesNativeCanvas = false
    var canvasMagnifications: [(scale: CGFloat?, attached: Bool)] = []
    func setCanvasMagnification(_ magnification: CGFloat?) {
        canvasMagnifications.append((magnification, view.window != nil))
    }
    let view: NSView = TestDisplayView(frame: NSRect(x: 0, y: 0, width: 390, height: 844))
    let input = InputView()
    var captureDisplayID: UInt32?
    var appDisplay: TestDisplay?
    var appDisplayError: (any Error)?
    var requestedDisplayUniqueIDs: [String] = []
    var holdsAppDisplayConnection = false
    var appDisplayConnection: CheckedContinuation<Void, Never>?
    func completeAppDisplayConnection() { appDisplayConnection?.resume(); appDisplayConnection = nil }
    func connectAppDisplay(uniqueID: String) async throws -> any DeviceSessionDisplay {
        requestedDisplayUniqueIDs.append(uniqueID)
        if holdsAppDisplayConnection { await withCheckedContinuation { appDisplayConnection = $0 } }
        if let appDisplayError { throw appDisplayError }
        guard let appDisplay else { throw SimulatorError.unavailable("No dedicated display") }
        return appDisplay
    }
    var inputView: NSView { foundPlugin?.overlayView ?? input }
    var plugin: SimulatorUserInterfacePlugin?
    var pluginError: Error?
    private var foundPlugin: SimulatorUserInterfacePlugin?
    func userInterfacePlugin() async throws -> SimulatorUserInterfacePlugin? {
        if let pluginError { throw pluginError }
        foundPlugin = plugin
        return plugin
    }
    var backlightState: Int32?
    var announcedRecordings: [Bool] = []
    func announceRecording(started: Bool) { announcedRecordings.append(started) }
    /// Size at scale 1, excluding the bezel.
    var naturalSize = NSSize(width: 390, height: 844)
    private(set) var renderScale: CGFloat = 1
    var screenScale: CGFloat? = 3
    var displayClass: UInt16? = 0
    var onPropertiesChange: (() -> Void)?
    var guestInterfaceAngle: Double?
    var isBooted = true
    var events: [(input: HIDInput, state: HIDState)] = []
    /// Runs before the event is recorded.
    var onSend: () -> Void = {}
    var deliveryError: Error?
    var undeliveredStates: Set<HIDState> = []
    /// Zero-based indices into the recorded events.
    var undeliveredEvents: Set<Int> = []
    var unavailableStates: Set<HIDState> = []
    var deferCompletions = false
    var pendingCompletions: [() -> Void] = []
    var created: [(state: HIDState, at: ContinuousClock.Instant)] = []
    var buttons: [DeviceButton] {
        events.compactMap { if case .button(let button) = $0.input, $0.state == .down { button } else { nil } }
    }
    var keyboard: [Bool] = []
    var disconnectCount = 0
    var onDisconnect: () -> Void = {}
    init() {
        defer { testDisplays.register(self) }
        view.addSubview(input)
        (view as? TestDisplayView)?.displaySize = { [unowned self] in size(for: renderScale) }
    }
    func message(for input: HIDInput, _ state: HIDState) throws -> HIDMessage {
        guard !unavailableStates.contains(state) else { throw SimulatorError.operation("No message") }
        created.append((state, ContinuousClock.now))
        return HIDMessage(input: input, state: state, pointer: OpaquePointer(try #require(malloc(1))))
    }
    func send(_ message: HIDMessage, completion: (@MainActor (Error?) -> Void)?) throws {
        onSend()
        let touch = touchMessages.removeValue(forKey: ObjectIdentifier(message))
        free(UnsafeMutableRawPointer(message.take()))
        let undelivered: Bool
        if let touch {
            remoteTouches.append(touch)
            undelivered = undeliveredTouches > 0 && touch.phase == .ended
            if undelivered { undeliveredTouches -= 1 }
        } else {
            events.append((message.input, message.state))
            undelivered = undeliveredStates.contains(message.state) || undeliveredEvents.contains(events.count - 1)
        }
        let error = undelivered ? SimulatorError.operation("Undelivered") : deliveryError
        if deferCompletions {
            pendingCompletions.append { completion?(error) }
        } else {
            completion?(error)
        }
    }
    /// Remote touches are recorded separately from events.
    var remoteTouches: [TVRemoteTouch] = []
    var undeliveredTouches = 0
    private var touchMessages: [ObjectIdentifier: TVRemoteTouch] = [:]
    func message(for touch: TVRemoteTouch) throws -> HIDMessage {
        let message = HIDMessage(input: .tvRemoteTouch, state: touch.phase == .ended ? .up : .down,
                                 pointer: OpaquePointer(try #require(malloc(1))))
        touchMessages[ObjectIdentifier(message)] = touch
        return message
    }
    var gestures: [WatchGesture] = []
    func send(_ gesture: WatchGesture, completion: @escaping @MainActor (Error?) -> Void) throws {
        gestures.append(gesture)
        completion(deliveryError)
    }
    /// The device's worker, for a test whose guest requests must go through a real one.
    var worker: HeldDeviceWorker?
    var appearanceToggles = 0
    func toggleAppearance() async throws {
        try await worker?.call("toggle the device's appearance")
        appearanceToggles += 1
    }
    var notificationStates: [String: UInt64] = [:]
    var postedNotifications: [String] = []
    var contentSize = 4
    var contrastMode = 1
    func postNotification(_ name: String) throws { postedNotifications.append(name) }
    var notificationError: Error?
    /// Fails only the post, once the state is set.
    var postError: Error?
    func sendNotificationState(_ name: String, to state: UInt64) async throws {
        try await worker?.call("change \(name) in the device")
        if let notificationError { throw notificationError }
        notificationStates[name] = state
        if let postError { throw GuestNotificationNotPosted(underlying: postError) }
        postedNotifications.append(name)
    }
    func updateNotificationState(_ name: String, _ change: @escaping @Sendable (UInt64) -> UInt64) async throws {
        try await sendNotificationState(name, to: change(notificationStates[name] ?? 0))
    }
    func updateContentSizeCategory(_ change: @escaping @Sendable (Int) throws -> Int?) throws {
        if let category = try change(contentSize) { contentSize = category }
    }
    func updateIncreaseContrast(_ change: @escaping @Sendable (Int) throws -> Bool) throws {
        contrastMode = try change(contrastMode) ? 2 : 1
    }
    func triggerCloudSync() async throws {}
    /// How many reads of the guest's state have started: reading what the menus show must not be one.
    private(set) var guestStateReads = 0
    func guestState(notifications: [String], debugOptions: [CADebugOption]) async throws -> GuestStateReading {
        guestStateReads += 1
        try await worker?.read("read the device's state")
        return GuestStateReading(
            notifications: Dictionary(uniqueKeysWithValues: notifications.map { ($0, notificationStates[$0] ?? 0) }),
            debugOptions: Dictionary(uniqueKeysWithValues: debugOptions.map { ($0.rawValue, caDebugOptions.contains($0)) }))
    }
    var logFolder = URL(fileURLWithPath: "/nonexistent")
    var memoryWarningURL = URL(fileURLWithPath: "/nonexistent/memory_warning_simulation")
    var caDebugOptions: Set<CADebugOption> = []
    /// CoreSimulator can silently drop these changes.
    var droppedCADebugOptions: Set<CADebugOption> = []
    func logDirectory() throws -> URL { logFolder }
    func memoryWarningFile() throws -> URL { memoryWarningURL }
    func toggleCADebugOption(_ option: CADebugOption) throws -> CADebugOptionChange {
        let enabled = !caDebugOptions.contains(option)
        if !droppedCADebugOptions.contains(option) {
            if enabled { caDebugOptions.insert(option) } else { caDebugOptions.remove(option) }
        }
        return CADebugOptionChange(requested: enabled, observed: caDebugOptions.contains(option))
    }
    var scenarios: [LocationScenario] = []
    var appliedLocations: [AppliedLocation] = []
    var locationError: Error?
    /// Simulates a newly booted device that lists scenarios late.
    var holdsScenarios = false
    private var heldListing: CheckedContinuation<Void, Never>?
    func locationScenarios() async throws -> [LocationScenario] {
        if holdsScenarios { await withCheckedContinuation { heldListing = $0 } }
        return scenarios
    }
    func releaseScenarios() {
        heldListing?.resume()
        heldListing = nil
    }
    func clearSimulatedLocation() async throws { try applyLocation(.cleared) }
    func setLocation(latitude: Double, longitude: Double) async throws {
        try applyLocation(.coordinate(latitude, longitude))
    }
    func setLocationScenario(_ name: String) async throws { try applyLocation(.scenario(name)) }
    private func applyLocation(_ location: AppliedLocation) throws {
        appliedLocations.append(location)
        if let locationError { throw locationError }
    }
    /// Added size at scale 1 while the bezel is visible.
    var bezel = NSSize.zero
    /// Nil means the device type has no bezel.
    var bezelPadding: NSSize?
    var chromePadding: NSSize? { showsBezel ? bezelPadding : nil }
    var deviceInsets = NSEdgeInsetsZero
    var deviceFrameReadCount = 0
    var deviceFrame: NSRect {
        deviceFrameReadCount += 1
        guard !usesNativeCanvas, chromePadding != nil else { return view.bounds }
        return NSRect(x: deviceInsets.left * renderScale, y: deviceInsets.bottom * renderScale,
                      width: view.bounds.width - (deviceInsets.left + deviceInsets.right) * renderScale,
                      height: view.bounds.height - (deviceInsets.top + deviceInsets.bottom) * renderScale)
    }
    var framebufferFrame: NSRect {
        guard !usesNativeCanvas, showsBezel else { return view.bounds }
        let size = NSSize(width: naturalSize.width * renderScale, height: naturalSize.height * renderScale)
        return NSRect(x: view.bounds.midX - size.width / 2, y: view.bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    /// SimDisplayView starts with showDeviceChrome enabled.
    var showsBezel = true
    private var outerSize: NSSize {
        showsBezel ? NSSize(width: naturalSize.width + bezel.width, height: naturalSize.height + bezel.height) : naturalSize
    }
    func setChromeVisible(_ visible: Bool) { showsBezel = visible }
    private(set) var showsResizeCursors = false
    func setShowsResizeCursors(_ shows: Bool) { showsResizeCursors = shows }
    private(set) var isResizing = false
    func setRenderScale(_ scale: CGFloat) {
        renderScale = scale
        view.setFrameSize(size(for: scale))
    }
    func size(for scale: CGFloat) -> NSSize { NSSize(width: outerSize.width * scale, height: outerSize.height * scale) }
    func scale(for size: NSSize) -> CGFloat { min(size.width / outerSize.width, size.height / outerSize.height) }
    func setKeyboardEnabled(_ enabled: Bool) { keyboard.append(enabled) }
    var trackpad: [Bool] = []
    func setTrackpadEnabled(_ enabled: Bool) { trackpad.append(enabled) }
    var hardwareKeyboard: [Bool] = []
    var keyboardLanguages: [String] = []
    var hardwareKeyboardError: Error?
    var keyboardLanguageError: Error?
    var keyboardLanguageDidChange: ((String) -> Void)?
    func setHardwareKeyboardConnected(_ connected: Bool) async throws {
        hardwareKeyboard.append(connected)
        if let hardwareKeyboardError { throw hardwareKeyboardError }
    }
    func setKeyboardLanguage(_ language: String) async throws {
        keyboardLanguages.append(language)
        if let keyboardLanguageError { throw keyboardLanguageError }
        keyboardLanguageDidChange?(language)
    }
    var pasteboards: [TestPasteboard] = []
    /// Fails once, then clears itself.
    var pasteboardError: Error?
    /// The Mac pasteboard that this display's connections manage.
    var managedPasteboard = NSPasteboard.general
    var hostPasteboardChangeCount: Int { managedPasteboard.changeCount }
    /// The native transport that a pasteboard route chose, when it chose one.
    var pasteboardTransport: (any PasteboardTransport)?
    /// What the latest connection reports to, from before it returns.
    private(set) var connectingPasteboardEvents: (@MainActor (SimulatorPasteboardEvent) -> Void)?
    private(set) var pasteboardConnectionAttempts = 0
    func connectPasteboard(sync: PasteboardSync?,
                           events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) async throws -> any SimulatorPasteboard {
        connectingPasteboardEvents = events
        pasteboardConnectionAttempts += 1
        if let pasteboardTransport {
            return NativePasteboardConnection(transport: pasteboardTransport, managing: managedPasteboard, sync: sync, events: events)
        }
        try await worker?.read("connect the device's pasteboard")
        if let error = pasteboardError {
            pasteboardError = nil
            throw error
        }
        let connection = TestPasteboard(pasteboard: managedPasteboard, events: events)
        pasteboards.append(connection)
        return connection
    }
    /// Nil simulates a failed port connection.
    var audioPort: TestAudioRoutes?
    var audioConnections = 0
    func connectAudioRoutes(changed: @escaping @MainActor (AudioRouteChange) -> Void) throws -> any SimulatorAudioRoutes {
        audioConnections += 1
        guard let audioPort else { throw SimulatorError.unavailable("The device has no audio route port.") }
        audioPort.changed = changed
        return audioPort
    }
    var hasScreenAdapter = true
    private(set) var externalScreen: TestExternalScreen?
    var externalScreenError: Error?
    private(set) var externalScreenRegistrations = 0
    /// SimulatorKit holds adapter registrations weakly.
    private var adapterRegistrations: [WeakAdapterRegistration] = []
    /// Queued reports retain their registration and can outlive the session's reference.
    private var queuedScreenReports: [() -> Void] = []
    func registerForExternalScreen(
        changed: @escaping @MainActor () -> Void,
        found: @escaping @MainActor (Result<any SimulatorExternalScreen, any Error>) -> Void
    ) throws -> AnyObject? {
        externalScreenRegistrations += 1
        guard hasScreenAdapter else { return nil }
        let registration = TestAdapterRegistration(changed: changed, found: found)
        adapterRegistrations.append(WeakAdapterRegistration(registration))
        if externalScreen != nil { queueScreenReport(to: registration) }
        return registration
    }
    func connectExternalScreen(_ screen: TestExternalScreen) {
        externalScreen = screen
        for registration in adapterRegistrations.compactMap(\.registration) { queueScreenReport(to: registration) }
    }
    var isRegisteredForExternalScreen: Bool { adapterRegistrations.contains { $0.registration != nil } }
    func deliverScreenReports() {
        let reports = queuedScreenReports
        queuedScreenReports = []
        for report in reports { report() }
    }
    private func queueScreenReport(to registration: TestAdapterRegistration) {
        guard let screen = externalScreen else { return }
        let error = externalScreenError
        queuedScreenReports.append {
            if let error { return registration.found(.failure(error)) }
            screen.changed = registration.changed
            registration.found(.success(screen))
        }
    }
    var supportsScrolling: [Bool] = []
    func setSupportsScrolling(_ supports: Bool) { supportsScrolling.append(supports) }
    var wantsEdgeSwipes: [Bool] = []
    func setWantsEdgeSwipes(_ wants: Bool) { wantsEdgeSwipes.append(wants) }
    var supportsTouchPressure: [Bool] = []
    var usesTrackpadForce: [Bool] = []
    var touchModes: [SimulatedTouchMode] = []
    func setSupportsTouchPressure(_ supports: Bool) { supportsTouchPressure.append(supports) }
    func setUsesTrackpadForce(_ uses: Bool) { usesTrackpadForce.append(uses) }
    func setSimulatedTouchMode(_ mode: SimulatedTouchMode) { touchModes.append(mode) }
    private(set) var touchIndicators: Set<TouchIndicator> = []
    func setTouchIndicator(_ indicator: TouchIndicator, shown: Bool) {
        if shown { touchIndicators.insert(indicator) } else { touchIndicators.remove(indicator) }
    }
    var rotations: [Double] = []
    /// Simulates SimulatorKit resizing the display after rotation.
    var onRotation: (Double) -> Void = { _ in }
    func setRotation(degrees: Double) {
        rotations.append(degrees)
        onRotation(degrees)
    }
    /// Updates the view after CoreSimulator reports a new screen size.
    func takeScreenSize(_ size: NSSize) {
        naturalSize = size
        view.setFrameSize(self.size(for: renderScale))
    }
    func beginResize() { isResizing = true }
    func endResize() { isResizing = false }
    func disconnect() { disconnectCount += 1; onDisconnect() }
    /// Holds each removal of the native input until `completeStop(throwing:)`.
    var holdsStop = false
    var heldStop: CheckedContinuation<Void, any Error>?
    private(set) var stopCount = 0
    func completeStop(throwing error: (any Error)? = nil) {
        if let error { heldStop?.resume(throwing: error) } else { heldStop?.resume() }
        heldStop = nil
    }
    func stop() async throws {
        stopCount += 1
        if holdsStop { try await withCheckedThrowingContinuation { heldStop = $0 } }
    }
}

/// A device's real channel and worker, whose calls block until `release()` while it holds them, as a native call blocks.
final class HeldDeviceWorker: Sendable {
    let channel: SimulatorDeviceChannel
    private let limit: Duration
    private let state = Mutex<(calls: [String], gate: DispatchSemaphore?)>(([], nil))

    init(limit: Duration = .seconds(10),
         channel: SimulatorDeviceChannel = SimulatorDeviceChannel(scope: .device(DeviceAddress(identifier: UUID().uuidString, deviceSetPath: nil)))) {
        self.channel = channel
        self.limit = limit
    }

    /// The calls that have reached the worker, in order.
    var calls: [String] { state.withLock { $0.calls } }

    func hold() { state.withLock { $0.gate = DispatchSemaphore(value: 0) } }

    func release() { state.withLock { state in defer { state.gate = nil }; return state.gate }?.signal() }

    func call(_ operation: String) async throws {
        try await channel.change(operation, limit: limit) { [self] in run(operation) }
    }

    func read(_ operation: String) async throws {
        try await channel.read(operation, limit: limit) { [self] in run(operation) }
    }

    private func run(_ operation: String) {
        let gate = state.withLock { state in
            state.calls.append(operation)
            return state.gate
        }
        gate?.wait()
    }
}

/// Records "input <route>" and "output <route>" requests; tests report external changes.
@MainActor
final class TestAudioRoutes: SimulatorAudioRoutes {
    var current: AudioRouteState
    private(set) var requests: [String] = []
    /// The device's worker, for a test whose reads must go through a real one.
    var worker: HeldDeviceWorker?
    private(set) var stateReads = 0
    /// Fails completion without changing the route.
    var routeError: Error?
    /// Throws before recording the request.
    var refusal: Error?
    var changed: ((AudioRouteChange) -> Void)?
    private(set) var isDisconnected = false

    init(_ devices: [HostAudioDevice], input: String = AudioRouting.systemDefault,
         output: String = AudioRouting.systemDefault) {
        current = AudioRouteState(devices: devices, inputRoute: input, outputRoute: output,
                                  defaultInput: devices.first { $0.isDefault(in: .input) }?.uid,
                                  defaultOutput: devices.first { $0.isDefault(in: .output) }?.uid)
    }

    func state() async throws -> AudioRouteState {
        stateReads += 1
        try await worker?.read("read the device's audio routes")
        return current
    }

    func route(_ scope: AudioScope, to route: String, completion: @escaping @MainActor (Error?) -> Void) throws {
        if let refusal { throw refusal }
        requests.append("\(scope.noun) \(route)")
        guard routeError == nil else { return completion(routeError) }
        completion(nil)
        report { state in
            if scope == .input { state.inputRoute = route } else { state.outputRoute = route }
        }
    }

    func disconnect() {
        isDisconnected = true
        changed = nil
    }

    func report(_ reason: AudioRouteChange = .selectedDevice, _ change: (inout AudioRouteState) -> Void) {
        change(&current)
        changed?(reason)
    }
}

/// Its lifetime controls the screen-adapter registration.
@MainActor
final class TestAdapterRegistration {
    let changed: @MainActor () -> Void
    let found: @MainActor (Result<any SimulatorExternalScreen, any Error>) -> Void
    init(changed: @escaping @MainActor () -> Void,
         found: @escaping @MainActor (Result<any SimulatorExternalScreen, any Error>) -> Void) {
        self.changed = changed
        self.found = found
    }
}

@MainActor
struct WeakAdapterRegistration {
    weak var registration: TestAdapterRegistration?
    init(_ registration: TestAdapterRegistration) { self.registration = registration }
}

/// iOS 26.5 TVOut modes: 720×480 at 60 Hz, menu sizes at 120 Hz, and iPhone ranges at 60 Hz.
extension ExternalScreenMode {
    static let exact720x480 = ExternalScreenMode(sizes: .exact(CGSize(width: 720, height: 480)), scale: 1,
                                                 refreshRate: 60)

    static func allowedAt120Hertz(scale: CGFloat) -> ExternalScreenMode {
        ExternalScreenMode(sizes: .allowed(ExternalDisplayMode.sizes.compactMap(\.pixelSize)), scale: scale,
                           refreshRate: 120)
    }

    static func rangeAt60Hertz(scale: CGFloat) -> ExternalScreenMode {
        ExternalScreenMode(sizes: .range(minimum: CGSize(width: 320, height: 200), maximum: CGSize(width: 3840, height: 2160)),
                           scale: scale, refreshRate: 60)
    }
}

/// Records display and CarPlay requests, with independently deferred reports and completions.
@MainActor
final class TestExternalScreen: SimulatorExternalScreen {
    let screenID: UInt32 = 2
    /// Identifies the boot that owns this screen.
    var deviceBootDate: Date? = Date(timeIntervalSinceReferenceDate: 0)
    var current = ExternalScreenState(isPoweredOn: false, pixelSize: CGSize(width: 720, height: 480), scale: 1)
    var modes = [1, 2].map {
        ExternalScreenMode(sizes: .range(minimum: CGSize(width: 1, height: 1), maximum: CGSize(width: 8192, height: 8192)),
                           scale: $0, refreshRate: 60)
    }
    private(set) var requests: [String] = []
    /// Fails completion without applying the change.
    var completionError: Error?
    /// Throws before recording the request.
    var refusal: Error?
    /// Throws after recording the request, whose completion can still arrive through `deliverCompletions()`.
    var unknownOutcome: Error?
    /// Errors keyed by request name; saving throws and other requests fail completion.
    var carPlayErrors: [String: Error] = [:]
    /// Mirrors CoreSimulatorBridge's session count, including invalid negative counts.
    private(set) var carPlaySessions = 0
    var defersCarPlaySessions = false
    private var pendingSessions: [() -> Void] = []
    var defersCarPlayServices = false
    private var pendingServices: [() -> Void] = []
    /// Reports and completions can arrive independently, in either order.
    var defersChanges = false
    private var pendingReports: [() -> Void] = []
    private var pendingCompletions: [() -> Void] = []
    var changed: (() -> Void)?
    /// The device's worker, for a test whose writes must go through a real one.
    var worker: HeldDeviceWorker?
    /// The same for CarPlay's requests alone, which a change reaches after requests that this leaves unheld.
    var carPlayWorker: HeldDeviceWorker?
    private(set) var displays: [TestDisplay] = []
    private(set) var isDisconnected = false

    func state() throws -> ExternalScreenState { current }

    func supportedModes() throws -> [ExternalScreenMode] { modes }

    func setMode(pixelSize: CGSize, scale: CGFloat, carPlay: Bool,
                 completion: @escaping @MainActor (Error?) -> Void) async throws {
        if let refusal { throw refusal }
        var outcome = unknownOutcome
        do { try await worker?.call("set the external display's mode") } catch {
            // A call that has started goes on, and CoreSimulator can still complete it.
            guard case .outcomeUnknown? = error as? DeviceOperationFailure else { throw error }
            outcome = error
        }
        requests.append("mode \(Int(pixelSize.width))x\(Int(pixelSize.height))@\(Int(scale))\(carPlay ? " carplay" : "")")
        complete(completion) {
            $0 = ExternalScreenState(isPoweredOn: true, pixelSize: pixelSize, scale: scale, isCarPlay: carPlay)
        }
        if let outcome { throw outcome }
    }

    func powerOff(completion: @escaping @MainActor (Error?) -> Void) async throws {
        if let refusal { throw refusal }
        try await worker?.call("turn off the external display")
        requests.append("off")
        complete(completion) { $0.isPoweredOn = false }
    }

    func saveCarPlayConfiguration(carPlay: Bool) throws {
        let request = carPlay ? "save carplay" : "save off"
        requests.append(request)
        if let error = carPlayErrors[request] { throw error }
    }

    func setCarPlayEnabled(_ enabled: Bool, inBoot boot: Date?, completion: @escaping @MainActor (Error?) -> Void) async {
        let request = enabled ? "start carplay" : "stop carplay"
        do { try await carPlayWorker?.call(request) } catch { return completion(error) }
        requests.append(request)
        let answer = { [self] in
            // The device checks its boot when the request executes.
            guard deviceBootDate == boot else { return completion(CarPlayRequestMoot()) }
            if let error = carPlayErrors[request] { return completion(error) }
            carPlaySessions += enabled ? 1 : -1
            completion(carPlaySessions < 0 ? SimulatorError.operation("invalid session count") : nil)
        }
        if defersCarPlaySessions { pendingSessions.append(answer) } else { answer() }
    }

    func deliverCarPlaySessions() {
        let answers = pendingSessions
        pendingSessions = []
        for answer in answers { answer() }
    }

    func setCarPlayService(connected: Bool, completion: @escaping @MainActor (Error?) -> Void) async throws {
        let request = connected ? "connect service" : "remove service"
        try await carPlayWorker?.call(request)
        requests.append(request)
        let answer = { [self] in completion(carPlayErrors[request]) }
        if defersCarPlayServices { pendingServices.append(answer) } else { answer() }
    }

    func deliverCarPlayServices() {
        let answers = pendingServices
        pendingServices = []
        for answer in answers { answer() }
    }

    func restart(boot: Date) {
        deviceBootDate = boot
        carPlaySessions = 0
    }

    private func complete(_ completion: @escaping @MainActor (Error?) -> Void,
                          _ change: @escaping (inout ExternalScreenState) -> Void) {
        let error = completionError
        let report = { [self] in if error == nil { self.report(change) } }
        guard defersChanges else {
            report()
            return completion(error)
        }
        pendingReports.append(report)
        pendingCompletions.append { completion(error) }
    }

    func deliver() {
        deliverReports()
        deliverCompletions()
    }

    func deliverReports() {
        let reports = pendingReports
        pendingReports = []
        for report in reports { report() }
    }

    func deliverCompletions() {
        let completions = pendingCompletions
        pendingCompletions = []
        for completion in completions { completion() }
    }

    var prepareDisplay: (() async -> Void)?

    func makeDisplay() async throws -> any DeviceSessionDisplay {
        await prepareDisplay?()
        let display = TestDisplay()
        display.naturalSize = NSSize(width: current.pixelSize.width / current.scale,
                                     height: current.pixelSize.height / current.scale)
        display.screenScale = current.scale
        display.displayClass = 1
        displays.append(display)
        return display
    }

    func disconnect() {
        isDisconnected = true
        changed = nil
    }

    func report(_ change: (inout ExternalScreenState) -> Void) {
        change(&current)
        changed?()
    }
}

/// Records transfers while tests supply device events.
@MainActor
final class TestPasteboard: SimulatorPasteboard {
    let pasteboard: NSPasteboard
    private let events: (SimulatorPasteboardEvent) -> Void
    private(set) var transfers: [PasteboardTransfer] = []
    private(set) var automaticSync: [Bool] = []
    private(set) var isDisconnected = false

    init(pasteboard: NSPasteboard, events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) {
        self.pasteboard = pasteboard
        self.events = events
    }

    func pull() throws { transfers.append(.get) }
    func push() throws { transfers.append(.send) }
    func setAutomaticSync(_ enabled: Bool) throws { automaticSync.append(enabled) }
    func disconnect() { isDisconnected = true }
    func send(_ event: SimulatorPasteboardEvent) { events(event) }
}

/// Records a CoreDevice pasteboard's transfers while tests report its observed changes.
@MainActor
final class TestPasteboardTransport: PasteboardTransport {
    private(set) var transfers: [PasteboardTransfer] = []
    var readError: (any Error)?
    /// Fails the sends that start while it is set.
    var sendError: (any Error)?
    /// Holds the sends that start while it is set until `completeSend()`.
    var holdsSends = false
    private var heldSendContinuations: [CheckedContinuation<Void, Never>] = []
    var heldSends: Int { heldSendContinuations.count }
    func completeSend() { heldSendContinuations.removeFirst().resume() }
    /// The observations in progress, and how many of the device's have started.
    private(set) var observations = 0
    private(set) var deviceObservations = 0
    /// The latest observations' change reports. A device change's write that replaces the Mac pasteboard asks
    /// `shouldReplace` just before it does, as the CoreDevice transport's write does.
    private(set) var reportDeviceChange: (@MainActor (@escaping @MainActor (_ shouldReplace: @escaping @MainActor () -> Bool) async throws -> Int?) -> Void)?
    private(set) var reportMacChange: (@MainActor (@escaping @MainActor () async throws -> Void) -> Void)?
    private var deviceObservationEnd: AsyncThrowingStream<Never, any Error>.Continuation?
    private var macObservationEnd: AsyncThrowingStream<Never, any Error>.Continuation?

    func read(into pasteboard: NSPasteboard) async throws -> Int {
        transfers.append(.get)
        if let readError { throw readError }
        return pasteboard.changeCount
    }
    func send(_ pasteboard: NSPasteboard) async throws {
        transfers.append(.send)
        let error = sendError
        if holdsSends { await withCheckedContinuation { heldSendContinuations.append($0) } }
        if let error { throw error }
    }
    func observeDeviceChanges(into pasteboard: NSPasteboard,
                              _ changed: @escaping @MainActor (@escaping @MainActor (@escaping @MainActor () -> Bool) async throws -> Int?) -> Void) async throws {
        let end = AsyncThrowingStream<Never, any Error>.makeStream()
        deviceObservations += 1
        deviceObservationEnd = end.continuation
        reportDeviceChange = changed
        try await observe(until: end.stream)
    }
    func observeChanges(of pasteboard: NSPasteboard,
                        _ changed: @escaping @MainActor (@escaping @MainActor () async throws -> Void) -> Void) async throws {
        let end = AsyncThrowingStream<Never, any Error>.makeStream()
        macObservationEnd = end.continuation
        reportMacChange = changed
        try await observe(until: end.stream)
    }
    func endDeviceObservation(throwing error: any Error) { deviceObservationEnd?.finish(throwing: error) }
    func endMacObservation() { macObservationEnd?.finish() }

    /// Counts the observation until `end` finishes or the task is cancelled.
    private func observe(until end: AsyncThrowingStream<Never, any Error>) async throws {
        observations += 1
        defer { observations -= 1 }
        for try await _ in end {}
        try Task.checkCancellation()
    }
}

@MainActor
func snapshot(of catalog: SimulatorCatalog) -> SimulatorCatalog.Snapshot {
    SimulatorCatalog.Snapshot(deviceTypes: catalog.deviceTypes, runtimes: catalog.runtimes,
                              supportedDeviceTypes: catalog.supportedDeviceTypes) { catalog.canPair($0, $1, $2, $3) }
}

@MainActor
final class TestCatalog: DeviceBrowserSource {
    var devices = [availableDevice("phone", "Phone", runtime: "iOS 27", state: 1)]
    var opened: [SimulatorDeviceIdentifier] = []
    var failure: Error?
    var reloadFailure: Error?
    var reloadedDevices: [AvailableDevice]?
    func availableSimulatorDevices() -> [AvailableDevice] { devices }
    func reloadSimulatorDevices() async throws {
        if let reloadFailure { throw reloadFailure }
        if let reloadedDevices { devices = reloadedDevices }
    }
    func openSimulator(withIdentifier identifier: SimulatorDeviceIdentifier) async throws {
        if let failure { throw failure }
        opened.append(identifier)
        devices = devices.map {
            var device = $0
            if device.identity == identifier { device.state = 3 }
            return device
        }
    }
}

func availableDevice(_ identifier: String, _ name: String, runtime: String, state: UInt, deviceSetPath: String? = nil) -> AvailableDevice {
    AvailableDevice(identifier: identifier, name: name, descriptiveName: "\(runtime) - \(name)",
                    runtimeIdentifier: "runtime \(runtime)", runtimeName: runtime,
                    productFamily: name.hasPrefix("iPad") ? 2 : 1, deviceTypeName: name, state: state, deviceSetPath: deviceSetPath)
}

// The fixture adds no mutable state to NSRunningApplication's Sendable contract.
final class FixtureRunningApplication: NSRunningApplication, @unchecked Sendable {
    private let reportedPID: pid_t
    private let reportedURL: URL?
    init(processIdentifier: pid_t = 101, bundleURL: URL? = nil) {
        reportedPID = processIdentifier
        reportedURL = bundleURL
        super.init()
    }
    override var processIdentifier: pid_t { reportedPID }
    override var bundleURL: URL? { reportedURL }
    override var bundleIdentifier: String? { "com.apple.dt.Devices" }
}

final class RendererOwnerMonitorFixture: Sendable {
    struct State {
        var exit: (@Sendable () -> Void)?
        var deadline: (@Sendable () -> Void)?
        var observedPID: Int32?
        var seconds: TimeInterval?
        var observationCancelled = false
        var deadlineCancelled = false
        var cleanupRequests = 0
        var forcedExits = 0
    }
    let state = Mutex(State())

    func makeMonitor() -> RendererOwnerMonitor {
        RendererOwnerMonitor(processIdentifier: 123, cleanup: { [self] in
            state.withLock { $0.cleanupRequests += 1 }
        }, observeExit: { [self] pid, exit in
            state.withLock { $0.observedPID = pid; $0.exit = exit }
            return { [self] in state.withLock { $0.observationCancelled = true } }
        }, scheduleDeadline: { [self] seconds, deadline in
            state.withLock { $0.seconds = seconds; $0.deadline = deadline }
            return { [self] in state.withLock { $0.deadlineCancelled = true } }
        }, forceExit: { [self] in state.withLock { $0.forcedExits += 1 } })
    }

    func exitOwner() { state.withLock { $0.exit }?() }
    func expireDeadline() { state.withLock { $0.deadline }?() }
}

@MainActor
final class TestRemoteScreenTransport: RemoteScreenTransport {
    var nativeInputView: NSView?
    var nativePoseControls: NativeDevicePoseControls?
    var inputCapabilities: Set<RemoteDeviceInputKind> = [.button]
    /// Maps window points to the screen's input locations; without it the screen takes no pointer input.
    var locate: ((CGPoint, Bool) -> RemoteDeviceInputLocations?)?
    private(set) var buttons: [RemoteDeviceButtonState] = []
    private(set) var keys: [(usage: UInt16, state: RemoteDeviceButtonState)] = []
    private(set) var touches: [(point: CGPoint, phase: RemoteDeviceTouchPhase)] = []
    private(set) var trackpadEvents: [NSEvent] = []
    private(set) var pointerMoves: [CGPoint] = []
    private(set) var pointerButtons: [RemoteDevicePointerPhase] = []
    private(set) var gesturePointers: [(event: NSEvent, transform: CGAffineTransform)] = []
    private(set) var inputReleases = 0
    var onReleaseInputs: (@MainActor () async throws -> Void)?
    private var events: (@MainActor (RemoteScreenTransportEvent) -> Void)?
    func emit(_ event: RemoteScreenTransportEvent) { events?(event) }
    func start(events: @escaping @MainActor (RemoteScreenTransportEvent) -> Void) async throws {
        self.events = events
        events(.connected)
        events(.attributes(.init(aspectRatio: CGSize(width: 400, height: 600), contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1), scaleFactor: 1, orientation: .portrait)))
        events(.frameReceived)
    }
    func send(_ input: RemoteScreenInput) async throws {
        if case .button(_, _, let state) = input { buttons.append(state) }
        if case .key(let usage, let state) = input { keys.append((usage, state)) }
        if case .touch(let point, _, let phase, _) = input { touches.append((point, phase)) }
        if case .trackpad(let event, _) = input { trackpadEvents.append(event) }
        if case .pointer(let point) = input { pointerMoves.append(point) }
        if case .pointerButton(_, let phase, _, _) = input { pointerButtons.append(phase) }
        if case .pointerEvent(let event, let transform) = input { gesturePointers.append((event, transform)) }
    }
    func inputLocations(atWindowPoint point: CGPoint, clampingToDisplay: Bool) -> RemoteDeviceInputLocations? {
        locate?(point, clampingToDisplay)
    }
    func releaseInputs() async throws {
        inputReleases += 1
        try await onReleaseInputs?()
    }
    func stop() async throws { nativeInputView?.removeFromSuperview() }
}

/// Stands in for the canvas around a remote screen, which magnifies the pinches the screen leaves to it.
final class MagnifyingCanvasFixture: NSView {
    private(set) var magnified: [NSEvent] = []
    override func magnify(with event: NSEvent) { magnified.append(event) }
}

/// The gesture phases of a trackpad's magnify events.
enum TrackpadPinchPhase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }

/// AppKit makes a trackpad's magnify event from a zoom gesture, IOHIDEvent type 8, with its phase and magnification.
func trackpadPinchEvent(_ phase: TrackpadPinchPhase, magnification: Double) throws -> NSEvent {
    let event = try #require(CGEvent(source: nil))
    event.type = try #require(CGEventType(rawValue: 29))
    event.setIntegerValueField(try #require(CGEventField(rawValue: 110)), value: 8)
    event.setIntegerValueField(try #require(CGEventField(rawValue: 132)), value: phase.rawValue)
    event.setDoubleValueField(try #require(CGEventField(rawValue: 113)), value: magnification)
    return try #require(NSEvent(cgEvent: event))
}
