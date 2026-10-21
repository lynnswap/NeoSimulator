import ABIBridge
import AppKit
import Darwin
import MachO
import ObjectiveC

// SimulatorKit passes rotations as Measurement<UnitAngle>, whose layout only
// its metadata establishes.
extension Measurement: @retroactive ABIBridgeSwiftValue where UnitType == UnitAngle {
    public static var swiftABIType: NativeType { try! .opaque(named: "Measurement") }
}

/// The private simulator interfaces of one Xcode.
///
/// Every interface the host uses is resolved during startup, so an
/// incompatible Xcode fails before the host changes any state.
@MainActor
final class SimulatorRuntime {
    let xcodeURL: URL
    let coreSimulator: CoreSimulatorInterface
    let display: SimulatorDisplayInterface
    let input: SimulatorInputInterface

    init(xcodeURL: URL) throws {
        self.xcodeURL = xcodeURL.resolvingSymlinksInPath()
        try Self.load(URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"))
        try Self.load(self.xcodeURL.appendingPathComponent("Contents/SharedFrameworks/SimulatorKit.framework"))
        try Self.load(self.xcodeURL.appendingPathComponent("Contents/Frameworks/IDEPlaygroundSimulator.framework"))
        let runtime = ABIRuntime.shared
        coreSimulator = try CoreSimulatorInterface(runtime: runtime)
        display = try SimulatorDisplayInterface(runtime: runtime)
        input = try SimulatorInputInterface(runtime: runtime)
        try validateLoadedImages()
    }

    private static func load(_ url: URL) throws {
        guard let executable = Bundle(url: url)?.executableURL else {
            throw HostError.unavailable("Missing framework at \(url.path)")
        }
        // Objective-C class registration outlives the handle. Loaded Apple
        // frameworks stay mapped for the lifetime of the host process.
        guard dlopen(executable.path, RTLD_NOW | RTLD_LOCAL) != nil else {
            let detail = dlerror().map { String(cString: $0) } ?? "Unknown loader error"
            throw HostError.unavailable("Could not load \(executable.path): \(detail)")
        }
    }

    func validateLoadedImages() throws {
        let prefix = xcodeURL.path + "/"
        for index in 0..<_dyld_image_count() {
            guard let pointer = _dyld_get_image_name(index) else { continue }
            let path = URL(fileURLWithPath: String(cString: pointer)).resolvingSymlinksInPath().path
            if path.contains("/DeviceKit.framework/") || path.contains("/DeviceHub.app/") {
                throw HostError.unavailable("Forbidden Device Hub component is loaded: \(path)")
            }
            if (path.contains("/SimulatorKit.framework/") || path.contains("/IDEPlaygroundSimulator.framework/")),
               !path.hasPrefix(prefix) {
                throw HostError.unavailable("Private simulator framework came from a different Xcode: \(path)")
            }
        }
    }

    /// Opens the default device set, or the set at `path`.
    func openDeviceSet(at path: String? = nil) throws -> SimulatorDeviceSet {
        try SimulatorDeviceSet(
            interface: coreSimulator,
            developerDirectory: xcodeURL.appendingPathComponent("Contents/Developer").path, path: path)
    }
}

/// SimulatorKit display members and the IDEPlaygroundSimulator display factory.
@MainActor
struct SimulatorDisplayInterface {
    let screenClass: AnyClass
    let makeScreen: NativeObjCMethod<AnyObject?, AnyObject, UInt32>
    let screen: NativeObjCMethod<AnyObject?>
    let isDefault: NativeObjCMethod<Bool>
    let isCarPlay: NativeObjCMethod<Bool>
    let buttonTarget: NativeSwiftMethod<() -> UInt32>
    typealias ScreenEventHandler = NativeSwiftClosure<(NativeSwiftBorrowedValue, NativeSwiftBorrowedValue) -> Void>
    /// `SimDeviceScreen.register(types:queue:handler:)`. Releasing the
    /// returned registration ends it.
    let registerScreenEvents: NativeSwiftMethod<(NativeSwiftValue, DispatchQueue, ScreenEventHandler) -> NativeSwiftValue>
    /// `SimDeviceScreen.ScreenEventTypes.properties`.
    let screenPropertyEvents: NativeSwiftValue
    /// `SimDeviceScreen.properties`, an `id<SimScreenProperties>`.
    let screenProperties: NativeSwiftMethod<() -> AnyObject>
    let factoryClass: AnyClass
    let createDisplay: NativeObjCMethod<NSView?, AnyObject, UInt32>
    let showChrome: NativeSwiftMethod<(Bool) -> Void>
    let chromeView: NativeSwiftMethod<() -> NSView>
    let digitizerView: NativeSwiftMethod<() -> NSView>
    let renderScale: NativeSwiftMethod<() -> CGFloat>
    let rotation: NativeSwiftMethod<(Measurement<UnitAngle>) -> Void>
    let disconnect: NativeSwiftMethod<(NativeSwiftClosure<() -> Void>) -> Void>
    let beginResize: NativeSwiftMethod<() -> Void>
    let resize: NativeSwiftMethod<(CGSize) -> Void>
    let endResize: NativeSwiftMethod<() -> Void>
    let chromeState: NativeSwiftType
    let setChromeState: NativeSwiftMethod<(NativeSwiftValue) -> Void>
    let setKeyboardEnabled: NativeSwiftMethod<(Bool) -> Void>
    let keyboardDelegate: Ivar

    init(runtime: ABIRuntime) throws {
        guard let screenClass = NSClassFromString("SimulatorKit.SimDeviceScreen"),
            let factoryClass = NSClassFromString("IDEPlaygroundSimulator.IDESimulatorPlaygroundUntil"),
            let displayClass = NSClassFromString("SimulatorKit.SimDisplayView")
        else {
            throw HostError.unavailable("SimulatorKit display classes are unavailable")
        }
        self.screenClass = screenClass
        self.factoryClass = factoryClass
        makeScreen = try runtime.resolveObjCMethodAndWait(
            on: screenClass, selector: "initWithDevice:screenID:", as: ((AnyObject, UInt32) -> AnyObject?).self)
        screen = try runtime.resolveObjCMethodAndWait(on: screenClass, selector: "screen", as: (() -> AnyObject?).self)
        isDefault = try runtime.resolveObjCMethodAndWait(on: screenClass, selector: "isDefault", as: (() -> Bool).self)
        isCarPlay = try runtime.resolveObjCMethodAndWait(on: screenClass, selector: "isCarPlay", as: (() -> Bool).self)
        let deviceScreen = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDeviceScreen")
        buttonTarget = try deviceScreen
            .resolveGetterAndWait(named: "buttonTarget.getter : __C.IndigoHIDTarget", as: (() -> UInt32).self)
        // The event types and events are resilient, so they are passed indirectly.
        let eventTypes = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDeviceScreen.ScreenEventTypes")
        let event = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDeviceScreen.ScreenEvent")
        let eventABIs: [NativeSwiftType: NativeType] = [
            eventTypes: try .opaque(named: eventTypes.name), event: try .opaque(named: event.name),
        ]
        screenPropertyEvents = try unsafe eventTypes
            .resolveStaticGetterAndWait(named: "properties", as: (() -> NativeSwiftValue).self, valueABIs: eventABIs)
            .unsafeInvoke()
        screenProperties = try deviceScreen.resolveGetterAndWait(
            named: "properties.getter : __C.SimScreenProperties", as: (() -> AnyObject).self)
        registerScreenEvents = try deviceScreen.resolveMethodAndWait(
            named: "register(types:queue:handler:)",
            as: ((NativeSwiftValue, DispatchQueue, ScreenEventHandler) -> NativeSwiftValue).self,
            valueABIs: eventABIs)
        createDisplay = try runtime.resolveObjCMethodAndWait(
            on: factoryClass, selector: "createSimDisplayViewWithDevice:simScreenID:",
            as: ((AnyObject, UInt32) -> NSView?).self, classMethod: true)

        // SimDisplayView members are exported only through dispatch thunks.
        let view = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDisplayView")
        showChrome = try view.resolveSetterAndWait(named: "showDeviceChrome", as: Bool.self)
        chromeView = try view.resolveGetterAndWait(
            named: "chromeView.getter : SimulatorKit.SimDisplayChromeView", as: (() -> NSView).self)
        digitizerView = try view.resolveGetterAndWait(
            named: "digitizerView.getter : SimulatorKit.SimDigitizerInputView", as: (() -> NSView).self)
        renderScale = try view.resolveGetterAndWait(named: "renderScale", as: (() -> CGFloat).self)
        rotation = try view.resolveSetterAndWait(named: "deviceRotation", as: Measurement<UnitAngle>.self)
        disconnect = try view.resolveMethodAndWait(
            named: "disconnect(completion: (() -> ())?) -> ()",
            as: ((NativeSwiftClosure<() -> Void>) -> Void).self)
        beginResize = try view.resolveMethodAndWait(named: "beginResize()", as: (() -> Void).self)
        resize = try view.resolveMethodAndWait(named: "resizeTo(size:)", as: ((CGSize) -> Void).self)
        endResize = try view.resolveMethodAndWait(named: "endResize()", as: (() -> Void).self)

        chromeState = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDisplayChromeView.State")
        setChromeState = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDisplayChromeView")
            .resolveSetterAndWait(
                named: "state.setter : SimulatorKit.SimDisplayChromeView.State",
                as: NativeSwiftValue.self,
                valueABIs: [chromeState: try .opaque(named: chromeState.name)])
        setKeyboardEnabled = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimKeyboardInputDefaultDelegate")
            .resolveSetterAndWait(named: "isEnabled", as: Bool.self)
        guard let keyboardDelegate = class_getInstanceVariable(displayClass, "_defaultKeyboardDelegate") else {
            throw HostError.unavailable("\(displayClass) does not provide _defaultKeyboardDelegate")
        }
        self.keyboardDelegate = keyboardDelegate
    }

    /// The device's default non-CarPlay screen, or nil while it is not ready.
    func defaultScreen(of device: SimulatorDevice) -> (identifier: UInt32, object: AnyObject)? {
        for identifier: UInt32 in 0...63 {
            // Invalid screen IDs raise exceptions, which arrive as errors;
            // absence is retried during boot.
            guard let allocated = allocate(screenClass),
                let screen = try? unsafe makeScreen.unsafeInvoke(on: allocated, device.object, identifier),
                let _ = try? unsafe self.screen.unsafeInvoke(on: screen),
                (try? unsafe isDefault.unsafeInvoke(on: screen)) == true,
                (try? unsafe isCarPlay.unsafeInvoke(on: screen)) == false
            else { continue }
            return (identifier, screen)
        }
        return nil
    }
}

/// The SimulatorKit HID client used for hardware buttons and HID usages.
@MainActor
struct SimulatorInputInterface {
    typealias Completion = @convention(block) (NSError?) -> Void

    let clientClass: AnyClass
    let makeClient: NativeObjCMethod<AnyObject, AnyObject>
    let send: NativeObjCMethod<Void, OpaquePointer, Bool, DispatchQueue?, Completion?>
    /// `IndigoHIDMessageForButton(button, state, target)`.
    let messageForButton: NativeFunction<OpaquePointer?, UInt32, UInt32, UInt32>
    /// `IndigoHIDMessageForHIDArbitrary(target, usagePage, usage, state)`.
    let messageForUsage: NativeFunction<OpaquePointer?, UInt32, UInt32, UInt32, UInt32>

    init(runtime: ABIRuntime) throws {
        guard let clientClass = NSClassFromString("SimulatorKit.SimDeviceLegacyHIDClient") else {
            throw HostError.unavailable("Required private class SimulatorKit.SimDeviceLegacyHIDClient is unavailable")
        }
        self.clientClass = clientClass
        makeClient = try runtime.resolveObjCMethodAndWait(
            on: clientClass, selector: "initWithDevice:error:", as: ((AnyObject) throws -> AnyObject).self)
        send = try runtime.resolveObjCMethodAndWait(
            on: clientClass, selector: "sendWithMessage:freeWhenDone:completionQueue:completion:",
            as: ((OpaquePointer, Bool, DispatchQueue?, Completion?) -> Void).self)
        messageForButton = try runtime.resolveCFunctionAndWait(
            named: "IndigoHIDMessageForButton", as: ((UInt32, UInt32, UInt32) -> OpaquePointer?).self)
        messageForUsage = try runtime.resolveCFunctionAndWait(
            named: "IndigoHIDMessageForHIDArbitrary",
            as: ((UInt32, UInt32, UInt32, UInt32) -> OpaquePointer?).self)
    }

    func connect(to device: SimulatorDevice) throws -> AnyObject {
        guard let allocated = allocate(clientClass) else {
            throw HostError.unavailable("Could not allocate simulator input")
        }
        return try unsafe makeClient.unsafeInvoke(on: allocated, device.object)
    }

    /// Creates the message for one event of `input` sent to `target`.
    func message(_ input: HIDInput, _ state: HIDState, target: UInt32) throws -> HIDMessage {
        let message = switch input {
        case .button(let button): try unsafe messageForButton.unsafeInvoke(button.rawValue, state.rawValue, target)
        case .usage(let page, let usage): try unsafe messageForUsage.unsafeInvoke(target, page, usage, state.rawValue)
        }
        guard let message else { throw HostError.operation("Could not allocate simulator input") }
        return HIDMessage(input: input, state: state, pointer: message)
    }

    /// Sends a message. SimulatorKit reports delivery to `completion` on the
    /// main queue.
    func send(_ hidMessage: HIDMessage, client: AnyObject, completion: (@MainActor (Error?) -> Void)?) throws {
        // The send transfers ownership of the message to SimulatorKit.
        let message = hidMessage.take()
        if let completion {
            // Build the block from a closure literal. Converting it inside
            // `Optional.map` makes Swift 6.3 emit a reabstraction thunk under
            // the block invoke function's mangled name, and the linker can pick
            // that thunk as the invoke of every such block, which then crashes.
            let handler: Completion = { error in MainActor.assumeIsolated { completion(error) } }
            try unsafe send.unsafeInvoke(on: client, message, true, .main, handler)
        } else {
            try unsafe send.unsafeInvoke(on: client, message, true, nil, nil)
        }
    }
}

/// An uninitialized instance for an Objective-C initializer, which consumes it.
@MainActor
private func allocate(_ type: AnyClass) -> AnyObject? {
    (type as? NSObject.Type)?.perform(NSSelectorFromString("alloc"))?.takeRetainedValue()
}

/// A hardware button, by its Indigo HID button number.
enum DeviceButton: UInt32 {
    case home = 0, lock = 1, applePay = 500, softwareKeyboard = 1008, siri = 1010
    /// The watch side button.
    case side = 3000
    /// The Action button on devices with the `com.apple.hid.sting` feature.
    case actionSting = 3001
    /// The Action button on devices with the `com.apple.hid.staccato` feature.
    case actionStaccato = 3002
}

/// An input Simulator.app sends as a down event and an up event.
enum HIDInput: Hashable {
    case button(DeviceButton)
    /// A HID usage, such as a key on the consumer usage page.
    case usage(page: UInt32, usage: UInt32)

    static let screenshot = HIDInput.usage(page: 0x0c, usage: 0x65)
    static let volumeUp = HIDInput.usage(page: 0x0c, usage: 0xe9)
    static let volumeDown = HIDInput.usage(page: 0x0c, usage: 0xea)
}

enum HIDState: UInt32 { case down = 1, up = 2 }

/// `SimScreenUIOrientation`, the guest's interface orientation.
enum SimScreenUIOrientation {
    /// The angle SimulatorKit's `SimScreenUIOrientation.toAngle()` gives a
    /// raw orientation: landscape 4 is shown at +90° and landscape 3 at -90°.
    static func displayAngle(_ rawValue: UInt32) -> Double {
        switch rawValue {
        case 2: 180
        case 3: -90
        case 4: 90
        default: 0
        }
    }
}

/// An Indigo HID message for one event. Sending transfers it to SimulatorKit;
/// a message that is not sent is freed.
final class HIDMessage {
    let input: HIDInput
    let state: HIDState
    private var pointer: OpaquePointer?

    init(input: HIDInput, state: HIDState, pointer: OpaquePointer) {
        self.input = input
        self.state = state
        self.pointer = pointer
    }

    func take() -> OpaquePointer {
        guard let pointer else { preconditionFailure("A HID message is sent once.") }
        self.pointer = nil
        return pointer
    }

    deinit { free(UnsafeMutableRawPointer(pointer)) }
}

@MainActor
protocol SimulatorDisplay: AnyObject {
    var isBooted: Bool { get }
    var view: NSView { get }
    var inputView: NSView { get }
    var naturalSize: NSSize { get }
    /// Called on the main actor when the screen's properties change, such as
    /// the interface orientation of the guest.
    var onPropertiesChange: (() -> Void)? { get set }
    /// The display angle for the guest's interface orientation, as SimulatorKit
    /// applies it when Rotate Device Automatically is on.
    var guestInterfaceAngle: Double? { get }
    /// Creates the message for one event of `input`, so that a command can
    /// prepare all of its events before it sends any.
    func message(for input: HIDInput, _ state: HIDState) throws -> HIDMessage
    /// Sends a message. `completion`, when present, receives SimulatorKit's
    /// delivery result; a thrown error means the message was not sent.
    func send(_ message: HIDMessage, completion: (@MainActor (Error?) -> Void)?) throws
    func toggleAppearance() throws
    /// Posts a Darwin notification in the guest.
    func postNotification(_ name: String) throws
    /// The guest's state of a Darwin notification.
    func notificationState(_ name: String) throws -> UInt64
    func setNotificationState(_ name: String, to state: UInt64) throws
    /// The guest's preferred text size, numbered as `SimulatorDevice` numbers it.
    func contentSizeCategory() throws -> Int
    func setContentSizeCategory(_ category: Int) throws
    /// 1 when Increase Contrast is off and 2 when it is on; 0 when unknown.
    func increaseContrastMode() throws -> Int
    func setIncreaseContrast(_ enabled: Bool) throws
    func triggerCloudSync() async throws
    /// The runtime's recorded location routes, in CoreSimulator's order.
    func locationScenarios() throws -> [LocationScenario]
    func clearSimulatedLocation() throws
    func setLocation(latitude: Double, longitude: Double) throws
    /// Runs the route a `LocationScenario.name` names.
    func setLocationScenario(_ name: String) throws
    func setChromeVisible(_ visible: Bool)
    func setActive(_ active: Bool)
    func setKeyboardEnabled(_ enabled: Bool)
    func setRotation(degrees: Double)
    func beginResize()
    func resize(to size: NSSize)
    func endResize()
    func disconnect()
}

@MainActor
final class SimulatorConnection: SimulatorDisplay {
    let view: NSView
    let inputView: NSView
    private let runtime: SimulatorRuntime
    private let chromeView: NSView
    private let device: SimulatorDevice
    private let buttonTarget: UInt32
    private var hidClient: AnyObject?
    private var disconnected = false
    var onPropertiesChange: (() -> Void)?
    private var screenEvents: NativeSwiftValue?
    private let screen: AnyObject

    init(device: SimulatorDevice, screen: (identifier: UInt32, object: AnyObject), runtime: SimulatorRuntime) throws {
        self.device = device
        self.runtime = runtime
        self.screen = screen.object
        let display = runtime.display
        buttonTarget = try unsafe display.buttonTarget.unsafeInvoke(on: screen.object)
        hidClient = try runtime.input.connect(to: device)
        guard let view = try unsafe display.createDisplay.unsafeInvoke(
            on: display.factoryClass as AnyObject, device.object, screen.identifier)
        else {
            throw HostError.unavailable("SimulatorKit returned no display")
        }
        self.view = view
        do {
            try runtime.validateLoadedImages()
            inputView = try unsafe display.digitizerView.unsafeInvoke(on: view)
            chromeView = try unsafe display.chromeView.unsafeInvoke(on: view)
        } catch {
            try? unsafe display.disconnect.unsafeInvoke(on: view, NativeSwiftClosure {})
            throw error
        }
        setChromeVisible(true)
        let handler = try SimulatorDisplayInterface.ScreenEventHandler { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onPropertiesChange?() }
        }
        screenEvents = try unsafe display.registerScreenEvents.unsafeInvoke(
            on: screen.object, display.screenPropertyEvents, .main, handler)
        // SimulatorKit connects keyboard input on every display and sends each modifier
        // change to all of them; the window controller enables it only while the window is key.
        setKeyboardEnabled(false)
    }

    var isBooted: Bool { !disconnected && device.state == 3 }

    var naturalSize: NSSize {
        let scale = (try? unsafe runtime.display.renderScale.unsafeInvoke(on: view)) ?? 0
        let size = view.intrinsicContentSize
        let actual = size.width > 0 && size.height > 0 ? size : view.frame.size
        return scale > 0 ? NSSize(width: actual.width / scale, height: actual.height / scale) : actual
    }

    var guestInterfaceAngle: Double? {
        guard !disconnected,
              let properties = try? unsafe runtime.display.screenProperties.unsafeInvoke(on: screen),
              let orientation = try? unsafe ABIRuntime.shared.object(properties)
                .resolveMethodAndWait(selector: "uiOrientation", as: (() -> UInt32).self).unsafeInvoke()
        else { return nil }
        return SimScreenUIOrientation.displayAngle(orientation)
    }

    func message(for input: HIDInput, _ state: HIDState) throws -> HIDMessage {
        try runtime.input.message(input, state, target: buttonTarget)
    }

    func send(_ message: HIDMessage, completion: (@MainActor (Error?) -> Void)?) throws {
        guard let hidClient else { throw HostError.operation("Simulator input is disconnected") }
        try runtime.input.send(message, client: hidClient, completion: completion)
    }

    func toggleAppearance() throws { try device.toggleAppearance() }
    func postNotification(_ name: String) throws { try device.postNotification(name) }
    func notificationState(_ name: String) throws -> UInt64 { try device.notificationState(name) }
    func setNotificationState(_ name: String, to state: UInt64) throws { try device.setNotificationState(name, to: state) }
    func contentSizeCategory() throws -> Int { try device.contentSizeCategory() }
    func setContentSizeCategory(_ category: Int) throws { try device.setContentSizeCategory(category) }
    func increaseContrastMode() throws -> Int { try device.increaseContrastMode() }
    func setIncreaseContrast(_ enabled: Bool) throws { try device.setIncreaseContrast(enabled) }
    func triggerCloudSync() async throws { try await device.triggerCloudSync() }
    func locationScenarios() throws -> [LocationScenario] { try device.locationScenarios() }
    func clearSimulatedLocation() throws { try device.clearSimulatedLocation() }
    func setLocation(latitude: Double, longitude: Double) throws {
        try device.setLocation(latitude: latitude, longitude: longitude)
    }
    func setLocationScenario(_ name: String) throws { try device.setLocationScenario(name) }
    func setChromeVisible(_ visible: Bool) {
        perform("show device chrome") { try unsafe runtime.display.showChrome.unsafeInvoke(on: view, visible) }
        view.invalidateIntrinsicContentSize()
    }
    func setActive(_ active: Bool) {
        guard !disconnected else { return }
        let display = runtime.display
        perform("activate device chrome") {
            let state = try display.chromeState.makeEnumCase(named: active ? "active" : "inactive")
            try unsafe display.setChromeState.unsafeInvoke(on: chromeView, state)
        }
    }
    func setKeyboardEnabled(_ enabled: Bool) {
        guard !disconnected, let keyboard = object_getIvar(view, runtime.display.keyboardDelegate) else { return }
        perform("enable keyboard input") {
            try unsafe runtime.display.setKeyboardEnabled.unsafeInvoke(on: keyboard as AnyObject, enabled)
        }
    }
    func setRotation(degrees: Double) {
        perform("rotate the display") {
            try unsafe runtime.display.rotation.unsafeInvoke(on: view, Measurement(value: degrees, unit: .degrees))
        }
        view.invalidateIntrinsicContentSize()
    }
    func beginResize() { perform("begin resizing") { try unsafe runtime.display.beginResize.unsafeInvoke(on: view) } }
    func resize(to size: NSSize) {
        perform("resize the display") { try unsafe runtime.display.resize.unsafeInvoke(on: view, size) }
        view.invalidateIntrinsicContentSize()
    }
    func endResize() { perform("end resizing") { try unsafe runtime.display.endResize.unsafeInvoke(on: view) } }
    func disconnect() {
        guard !disconnected else { return }
        disconnected = true
        perform("disconnect the display") {
            try unsafe runtime.display.disconnect.unsafeInvoke(on: view, NativeSwiftClosure {})
        }
        // Releasing the registration ends the screen events.
        screenEvents = nil
        onPropertiesChange = nil
        hidClient = nil
    }
    isolated deinit { disconnect() }

    // These members were prepared during startup; a failure here means
    // SimulatorKit rejected the value, which the display cannot recover from.
    private func perform(_ operation: String, _ body: () throws -> Void) {
        do { try body() } catch { hostLog("Could not \(operation): \(error.localizedDescription)") }
    }
}
