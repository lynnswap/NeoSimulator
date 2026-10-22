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
    let pasteboard: SimulatorPasteboardInterface

    init(xcodeURL: URL) throws {
        self.xcodeURL = xcodeURL.resolvingSymlinksInPath()
        try Self.load(URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"))
        try Self.load(self.xcodeURL.appendingPathComponent("Contents/SharedFrameworks/SimulatorKit.framework"))
        try Self.load(self.xcodeURL.appendingPathComponent("Contents/Frameworks/IDEPlaygroundSimulator.framework"))
        let runtime = ABIRuntime.shared
        coreSimulator = try CoreSimulatorInterface(runtime: runtime)
        display = try SimulatorDisplayInterface(runtime: runtime)
        input = try SimulatorInputInterface(runtime: runtime)
        pasteboard = try SimulatorPasteboardInterface(runtime: runtime)
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
    /// `SimDeviceScreen.scale`, the screen's pixels per point.
    let screenScale: NativeSwiftMethod<() -> CGFloat>
    /// `SimDeviceScreen.displayClass`.
    let displayClass: NativeSwiftMethod<() -> UInt16>
    let factoryClass: AnyClass
    let createDisplay: NativeObjCMethod<NSView?, AnyObject, UInt32>
    let showChrome: NativeSwiftMethod<(Bool) -> Void>
    let chromeView: NativeSwiftMethod<() -> NSView>
    let digitizerView: NativeSwiftMethod<() -> NSView>
    let renderScale: NativeSwiftMethod<() -> CGFloat>
    let setRenderScale: NativeSwiftMethod<(CGFloat) -> Void>
    /// `SimDisplayView.size(for:)`.
    let sizeForScale: NativeSwiftMethod<(CGFloat) -> CGSize>
    /// `SimDisplayView.scale(for:)`.
    let scaleForSize: NativeSwiftMethod<(CGSize) -> CGFloat>
    let rotation: NativeSwiftMethod<(Measurement<UnitAngle>) -> Void>
    let disconnect: NativeSwiftMethod<(NativeSwiftClosure<() -> Void>) -> Void>
    let beginResize: NativeSwiftMethod<() -> Void>
    let resize: NativeSwiftMethod<(CGSize) -> Void>
    let endResize: NativeSwiftMethod<() -> Void>
    /// `SimDisplayView.typedResizeRects`, an array of `SimDisplayView.TypedResizeRect`.
    let resizeRects: NativeSwiftMethod<() -> NativeSwiftValue>
    /// That array's `count` and subscript.
    let resizeRectCount: NativeSwiftMethod<() -> Int>
    let resizeRectAtIndex: NativeSwiftMethod<(Int) -> NativeSwiftValue>
    /// `SimDisplayView.TypedResizeRect.rect`.
    let resizeRectFrame: NativeSwiftMethod<() -> CGRect>
    /// `SimDisplayView.TypedResizeRect.type`, a `SimDeviceChrome.ResizeRectType`.
    let resizeRectType: NativeSwiftMethod<() -> NativeSwiftValue>
    /// `SimDeviceChrome.ResizeRectType.rawValue`.
    let resizeRectTypeName: NativeSwiftMethod<() -> String>
    /// `SimDisplayView.showResizeCursors`.
    let showResizeCursors: NativeSwiftMethod<(Bool) -> Void>
    let chromeState: NativeSwiftType
    let setChromeState: NativeSwiftMethod<(NativeSwiftValue) -> Void>
    /// `SimDisplayChromeView.chrome`, an optional `SimDeviceChrome`.
    let chrome: NativeSwiftMethod<() -> NativeSwiftValue>
    /// `SimDeviceChrome.images`.
    let chromeImages: NativeSwiftMethod<() -> NativeSwiftValue>
    /// `SimDeviceChrome.Images.padding`.
    let chromeImagesPadding: NativeSwiftMethod<() -> CGSize>
    let setKeyboardEnabled: NativeSwiftMethod<(Bool) -> Void>
    let keyboardDelegate: Ivar
    /// `SimDigitizerInputView.supportTouchPressure`.
    let setSupportsTouchPressure: NativeSwiftMethod<(Bool) -> Void>
    /// `SimDigitizerInputView.useForceTrackpadForPressure`.
    let setUsesTrackpadForce: NativeSwiftMethod<(Bool) -> Void>
    /// `SimDigitizerInputView.simulatedTouchMode`, a `TouchMode` passed as
    /// its raw value: see `SimulatedTouchMode`.
    let setSimulatedTouchMode: NativeSwiftMethod<(Int) -> Void>
    /// `SimDigitizerInputView.drawOptions`, a `DrawOption` option set, which
    /// is resilient and so passed indirectly.
    let drawOptions: NativeSwiftMethod<() -> NativeSwiftValue>
    let setDrawOptions: NativeSwiftMethod<(NativeSwiftValue) -> Void>
    /// `DrawOption.rawValue` and `DrawOption(rawValue:)`.
    let drawOptionRawValue: NativeSwiftMethod<() -> Int>
    let makeDrawOption: NativeSwiftFunction<(Int) -> NativeSwiftValue>
    /// The raw values of `DrawOption.normalTouch`, `.pinchTouches`,
    /// `.pinchPivotPoint`, and `.edgeGestures`.
    private let touchIndicatorOptions: (singleTouches: Int, pinches: Int, pinchPivotPoint: Int, edgeGestures: Int)

    init(runtime: ABIRuntime) throws {
        guard let screenClass = NSClassFromString("SimulatorKit.SimDeviceScreen"),
            let factoryClass = NSClassFromString("IDEPlaygroundSimulator.IDESimulatorPlaygroundUntil"),
            let displayViewClass = NSClassFromString("SimulatorKit.SimDisplayView")
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
        screenScale = try deviceScreen.resolveGetterAndWait(
            named: "scale.getter : CoreGraphics.CGFloat", as: (() -> CGFloat).self)
        // CoreSimulator declares `SimDisplayClass` as an unsigned short.
        displayClass = try deviceScreen.resolveGetterAndWait(
            named: "displayClass.getter : __C.SimDisplayClass", as: (() -> UInt16).self)
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
        setRenderScale = try view.resolveSetterAndWait(named: "renderScale", as: CGFloat.self)
        sizeForScale = try view.resolveMethodAndWait(named: "size(for:)", as: ((CGFloat) -> CGSize).self)
        scaleForSize = try view.resolveMethodAndWait(named: "scale(for:)", as: ((CGSize) -> CGFloat).self)
        rotation = try view.resolveSetterAndWait(named: "deviceRotation", as: Measurement<UnitAngle>.self)
        disconnect = try view.resolveMethodAndWait(
            named: "disconnect(completion: (() -> ())?) -> ()",
            as: ((NativeSwiftClosure<() -> Void>) -> Void).self)
        beginResize = try view.resolveMethodAndWait(named: "beginResize()", as: (() -> Void).self)
        resize = try view.resolveMethodAndWait(named: "resizeTo(size:)", as: ((CGSize) -> Void).self)
        endResize = try view.resolveMethodAndWait(named: "endResize()", as: (() -> Void).self)
        // The resize corners and their types are resilient, so they are passed
        // indirectly, and the array's own members read its elements.
        let typedResizeRect = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDisplayView.TypedResizeRect")
        let typedResizeRects = try runtime.resolveSwiftTypeAndWait(
            named: "Swift.Array", genericArguments: [.type(typedResizeRect)])
        let resizeRectType = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDeviceChrome.ResizeRectType")
        resizeRects = try view.resolveGetterAndWait(
            named: "typedResizeRects.getter : [SimulatorKit.SimDisplayView.TypedResizeRect]",
            as: (() -> NativeSwiftValue).self)
        resizeRectCount = try typedResizeRects.resolveGetterAndWait(named: "count", as: (() -> Int).self)
        resizeRectAtIndex = try typedResizeRects.resolveMethodAndWait(
            named: "Swift.Array.subscript.getter : (Swift.Int) -> A", as: ((Int) -> NativeSwiftValue).self)
        resizeRectFrame = try typedResizeRect.resolveGetterAndWait(
            named: "rect.getter : __C.CGRect", as: (() -> CGRect).self, receiverABI: .opaque(named: typedResizeRect.name))
        self.resizeRectType = try typedResizeRect.resolveGetterAndWait(
            named: "type.getter : SimulatorKit.SimDeviceChrome.ResizeRectType", as: (() -> NativeSwiftValue).self,
            valueABIs: [resizeRectType: try .opaque(named: resizeRectType.name)],
            receiverABI: .opaque(named: typedResizeRect.name))
        resizeRectTypeName = try resizeRectType.resolveGetterAndWait(
            named: "rawValue.getter : Swift.String", as: (() -> String).self,
            receiverABI: .opaque(named: resizeRectType.name))
        showResizeCursors = try view.resolveSetterAndWait(named: "showResizeCursors", as: Bool.self)

        chromeState = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDisplayChromeView.State")
        let chromeViewType = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDisplayChromeView")
        setChromeState = try chromeViewType.resolveSetterAndWait(
            named: "state.setter : SimulatorKit.SimDisplayChromeView.State",
            as: NativeSwiftValue.self,
            valueABIs: [chromeState: try .opaque(named: chromeState.name)])
        // The chrome and its images are resilient, so they are passed indirectly.
        let deviceChrome = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDeviceChrome")
        let optionalChrome = try runtime.resolveSwiftTypeAndWait(named: "Swift.Optional",
                                                                 genericArguments: [.type(deviceChrome)])
        let images = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDeviceChrome.Images")
        chrome = try chromeViewType.resolveGetterAndWait(
            named: "chrome.getter : SimulatorKit.SimDeviceChrome?", as: (() -> NativeSwiftValue).self,
            valueABIs: [optionalChrome: try .opaque(named: optionalChrome.name)])
        chromeImages = try deviceChrome.resolveGetterAndWait(
            named: "images.getter : SimulatorKit.SimDeviceChrome.Images", as: (() -> NativeSwiftValue).self,
            valueABIs: [images: try .opaque(named: images.name)], receiverABI: .opaque(named: deviceChrome.name))
        chromeImagesPadding = try images.resolveGetterAndWait(
            named: "padding.getter : __C.CGSize", as: (() -> CGSize).self, receiverABI: .opaque(named: images.name))
        setKeyboardEnabled = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimKeyboardInputDefaultDelegate")
            .resolveSetterAndWait(named: "isEnabled", as: Bool.self)
        guard let keyboardDelegate = class_getInstanceVariable(displayViewClass, "_defaultKeyboardDelegate") else {
            throw HostError.unavailable("\(displayViewClass) does not provide _defaultKeyboardDelegate")
        }
        self.keyboardDelegate = keyboardDelegate
        let digitizer = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDigitizerInputView")
        setSupportsTouchPressure = try digitizer.resolveSetterAndWait(named: "supportTouchPressure", as: Bool.self)
        setUsesTrackpadForce = try digitizer.resolveSetterAndWait(named: "useForceTrackpadForPressure", as: Bool.self)
        setSimulatedTouchMode = try digitizer.resolveSetterAndWait(
            named: "simulatedTouchMode.setter : SimulatorKit.SimDigitizerInputView.TouchMode", as: Int.self)
        let drawOption = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDigitizerInputView.DrawOption")
        let drawOptionABIs: [NativeSwiftType: NativeType] = [drawOption: try .opaque(named: drawOption.name)]
        drawOptions = try digitizer.resolveGetterAndWait(
            named: "drawOptions.getter : SimulatorKit.SimDigitizerInputView.DrawOption",
            as: (() -> NativeSwiftValue).self, valueABIs: drawOptionABIs)
        setDrawOptions = try digitizer.resolveSetterAndWait(
            named: "drawOptions.setter : SimulatorKit.SimDigitizerInputView.DrawOption",
            as: NativeSwiftValue.self, valueABIs: drawOptionABIs)
        let rawValue = try drawOption.resolveGetterAndWait(
            named: "rawValue.getter : Swift.Int", as: (() -> Int).self, receiverABI: .opaque(named: drawOption.name))
        drawOptionRawValue = rawValue
        makeDrawOption = try drawOption.resolveInitializerAndWait(
            named: "init(rawValue:)", as: ((Int) -> NativeSwiftValue).self, valueABIs: drawOptionABIs)
        func option(_ name: String) throws -> Int {
            try unsafe rawValue.unsafeInvoke(on: drawOption.resolveStaticGetterAndWait(
                named: name, as: (() -> NativeSwiftValue).self, valueABIs: drawOptionABIs).unsafeInvoke())
        }
        touchIndicatorOptions = (try option("normalTouch"), try option("pinchTouches"), try option("pinchPivotPoint"),
                                 try option("edgeGestures"))
    }

    /// The raw value of `indicator`'s `DrawOption`.
    func drawOption(for indicator: TouchIndicator) -> Int {
        switch indicator {
        case .singleTouches: touchIndicatorOptions.singleTouches
        case .pinches: touchIndicatorOptions.pinches
        case .pinchPivotPoint: touchIndicatorOptions.pinchPivotPoint
        case .edgeGestures: touchIndicatorOptions.edgeGestures
        }
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
    /// `IndigoHIDGetKeyboardType()`, the type of the Mac's keyboard.
    let keyboardType: NativeFunction<UInt32>

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
        keyboardType = try runtime.resolveCFunctionAndWait(named: "IndigoHIDGetKeyboardType", as: (() -> UInt32).self)
    }

    /// The Mac keyboard's type, which `SimDevice` takes as a byte when it
    /// connects the guest's hardware keyboard. Simulator.app traps on a type
    /// that does not fit; this reports it.
    func currentKeyboardType() throws -> UInt8 {
        let type = try unsafe keyboardType.unsafeInvoke()
        guard let byte = UInt8(exactly: type) else {
            throw HostError.operation("SimulatorKit reported keyboard type \(type), which the device cannot take.")
        }
        return byte
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

/// SimPasteboardPlus, which CoreSimulator loads: the host end of a device's
/// pasteboard connection, which Simulator.app and `simctl pbsync` use.
@MainActor
struct SimulatorPasteboardInterface {
    let interfaceClass: AnyClass
    /// `initWithConnectingToPort:managingPasteboard:delegate:delegateQueue:`.
    let makeInterface: NativeObjCMethod<AnyObject, UInt32, NSPasteboard, AnyObject?, DispatchQueue?>
    /// Sends the managed pasteboard to the device.
    let push: NativeObjCMethod<Void>
    /// Asks the device for its pasteboard, which then replaces the managed one.
    let pull: NativeObjCMethod<Void>
    /// Start and stop the automatic synchronization of Edit ▸ Automatically
    /// Sync Pasteboard.
    let enableAutomaticSync: NativeObjCMethod<Void>
    let disableAutomaticSync: NativeObjCMethod<Void>
    /// The guest's pasteboard service, `SimPasteboardInterfaceListener.machServiceName`.
    let serviceName: String

    init(runtime: ABIRuntime) throws {
        guard let interfaceClass = NSClassFromString("SimPasteboardPlus.SimPasteboardInterface"),
              let listenerClass = NSClassFromString("SimPasteboardPlus.SimPasteboardInterfaceListener") else {
            throw HostError.unavailable("SimPasteboardPlus pasteboard classes are unavailable")
        }
        self.interfaceClass = interfaceClass
        makeInterface = try runtime.resolveObjCMethodAndWait(
            on: interfaceClass, selector: "initWithConnectingToPort:managingPasteboard:delegate:delegateQueue:",
            as: ((UInt32, NSPasteboard, AnyObject?, DispatchQueue?) -> AnyObject).self)
        push = try runtime.resolveObjCMethodAndWait(on: interfaceClass, selector: "push", as: (() -> Void).self)
        pull = try runtime.resolveObjCMethodAndWait(on: interfaceClass, selector: "pull", as: (() -> Void).self)
        enableAutomaticSync = try runtime.resolveObjCMethodAndWait(
            on: interfaceClass, selector: "enableRemoteAutosync", as: (() -> Void).self)
        disableAutomaticSync = try runtime.resolveObjCMethodAndWait(
            on: interfaceClass, selector: "disableRemoteAutosync", as: (() -> Void).self)
        serviceName = try unsafe runtime.resolveObjCMethodAndWait(
            on: listenerClass, selector: "machServiceName", as: (() -> String).self, classMethod: true)
            .unsafeInvoke(on: listenerClass as AnyObject)
    }

    /// Connects to the device's pasteboard service, managing `pasteboard`.
    /// Connecting transfers nothing, and the connection synchronizes only
    /// after `enableRemoteAutosync`.
    func connect(to device: SimulatorDevice, managing pasteboard: NSPasteboard,
                 events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) throws -> SimulatorPasteboardConnection {
        let port = try device.lookUp(serviceName)
        guard let allocated = allocate(interfaceClass) else {
            throw HostError.unavailable("Could not allocate the simulator's pasteboard connection")
        }
        // The interface calls the delegate on the main queue; the connection keeps it.
        let delegate = SimulatorPasteboardDelegate(events)
        let object = try unsafe makeInterface.unsafeInvoke(on: allocated, port, pasteboard, delegate, .main)
        return SimulatorPasteboardConnection(object: object, delegate: delegate, interface: self)
    }
}

/// A SimPasteboardPlus callback about a device's pasteboard connection.
enum SimulatorPasteboardEvent {
    /// The connection became active: once after connecting, and again each
    /// time the device has taken a push, which `simctl pbsync` waits for.
    case activated
    /// The device's pasteboard replaced the managed pasteboard, after a pull
    /// or, while synchronizing, a copy on the device. `generation` is the
    /// managed pasteboard's change count after the change.
    case applied(generation: Int)
    /// Writing the device's pasteboard to the managed pasteboard failed.
    case failedToApply(Error)
    /// The device closed the connection. Later pushes and pulls on it do nothing.
    case lostConnection
    /// The connection started or stopped synchronizing automatically.
    case synchronizationChanged(Bool)
}

/// A device's pasteboard connection. Releasing it closes the connection.
@MainActor
protocol SimulatorPasteboard: AnyObject {
    /// SimPasteboardPlus `pull`: Edit ▸ Get Pasteboard.
    func pull() throws
    /// SimPasteboardPlus `push`: Edit ▸ Send Pasteboard.
    func push() throws
    /// SimPasteboardPlus `enableRemoteAutosync` or `disableRemoteAutosync`.
    /// While enabled, a change of the managed pasteboard reaches the device,
    /// and a copy on the device replaces the managed pasteboard. Enabling
    /// transfers nothing by itself.
    func setAutomaticSync(_ enabled: Bool) throws
    /// Stops the connection's events.
    func disconnect()
}

@MainActor
final class SimulatorPasteboardConnection: SimulatorPasteboard {
    private let object: AnyObject
    private let delegate: SimulatorPasteboardDelegate
    private let interface: SimulatorPasteboardInterface

    fileprivate init(object: AnyObject, delegate: SimulatorPasteboardDelegate, interface: SimulatorPasteboardInterface) {
        self.object = object
        self.delegate = delegate
        self.interface = interface
    }

    func pull() throws { try unsafe interface.pull.unsafeInvoke(on: object) }
    func push() throws { try unsafe interface.push.unsafeInvoke(on: object) }
    func setAutomaticSync(_ enabled: Bool) throws {
        try unsafe (enabled ? interface.enableAutomaticSync : interface.disableAutomaticSync).unsafeInvoke(on: object)
    }
    func disconnect() { delegate.events = nil }
}

/// Forwards the `SimPasteboardDelegate` callbacks that the host needs, which
/// the connection makes on the main queue. Every method of that protocol is
/// optional, and the connection does not check conformance.
@MainActor
final class SimulatorPasteboardDelegate: NSObject {
    var events: ((SimulatorPasteboardEvent) -> Void)?

    init(_ events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) { self.events = events }

    @objc func simPasteboardDidBecomeActive(_ interface: AnyObject) { events?(.activated) }

    @objc func simPasteboardDidLoseConnection(_ interface: AnyObject) { events?(.lostConnection) }

    @objc func simPasteboardDidApplySnapshot(_ interface: AnyObject, fromHost host: NSUUID, incomingGeneration: Int64,
                                             toPasteboard pasteboard: NSPasteboard, atGeneration generation: Int64) {
        events?(.applied(generation: Int(generation)))
    }

    @objc func simPasteboardErrorApplyingSnapshot(_ interface: AnyObject, fromHost host: NSUUID, generation: Int64,
                                                  error: NSError, toPasteboard pasteboard: NSPasteboard) {
        events?(.failedToApply(error))
    }

    @objc func simPasteboardDidChangeAutoNotifyState(_ interface: AnyObject, forPasteboard pasteboard: NSPasteboard,
                                                     toStatus enabled: Bool) {
        events?(.synchronizationChanged(enabled))
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

/// A Core Animation debug option of the guest, numbered as
/// `SimDevice setCADebugOption:enabled:` numbers it.
enum CADebugOption: UInt32 {
    case colorCopiedImages = 1
    case colorBlendedLayers = 2
    case colorMisalignedImages = 14
    case colorOffscreenRendered = 17

    /// The Debug menu's title for the option.
    var title: String {
        switch self {
        case .colorCopiedImages: "Color Copied Images"
        case .colorBlendedLayers: "Color Blended Layers"
        case .colorMisalignedImages: "Color Misaligned Images"
        case .colorOffscreenRendered: "Color Off-screen Rendered"
        }
    }
}

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

/// `SimDigitizerInputView.TouchMode`, by its raw value: how hard a click
/// presses while the trackpad's force does not decide, I/O ▸ Touch Pressure ▸
/// Shallow Press or Deep Press.
enum SimulatedTouchMode: Int {
    case shallow = 0, deep = 1
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

/// An area at a corner of the bezel whose drag resizes the window,
/// `SimDisplayView.TypedResizeRect`.
struct DisplayResizeRect {
    /// `SimDeviceChrome.ResizeRectType`, by its raw value: the corner of the
    /// display that the drag moves.
    enum Corner: String {
        case lowerLeft, lowerRight, upperRight, upperLeft

        var isLeft: Bool { self == .lowerLeft || self == .upperLeft }
        var isLower: Bool { self == .lowerLeft || self == .lowerRight }
    }

    var corner: Corner
    var rect: NSRect
}

@MainActor
protocol SimulatorDisplay: AnyObject {
    var isBooted: Bool { get }
    var view: NSView { get }
    var inputView: NSView { get }
    /// `SimDisplayView.renderScale`: the display's size relative to the
    /// device's screen in points, which the screen's resolution does not change.
    var renderScale: CGFloat { get }
    func setRenderScale(_ scale: CGFloat)
    /// The display's size at `scale`, with the bezel when it is shown.
    func size(for scale: CGFloat) -> NSSize
    /// The largest scale at which the display fits `size`.
    func scale(for size: NSSize) -> CGFloat
    /// `SimDeviceScreen.scale`, the screen's pixels per point, or nil when unknown.
    var screenScale: CGFloat? { get }
    /// `SimDeviceScreen.displayClass`, or nil when unknown; 0 is a device's own screen.
    var displayClass: UInt16? { get }
    /// The padding of the bezel the display shows, `SimDeviceChrome.images.padding`,
    /// or nil when it shows none: `SimDisplayChromeView.chrome` is nil while the
    /// bezel is hidden and for a device type without one.
    var chromePadding: NSSize? { get }
    /// The areas at the bezel's corners whose drag resizes the window,
    /// `SimDisplayView.typedResizeRects`, in `view`'s coordinates at the
    /// display's scale; none without a bezel. SimulatorKit leaves clicks in
    /// them to the window.
    var resizeRects: [DisplayResizeRect] { get }
    /// `SimDisplayView.showResizeCursors`: whether the view shows resize
    /// cursors over `resizeRects`.
    func setShowsResizeCursors(_ shows: Bool)
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
    /// The folder of the device's logs.
    func logDirectory() throws -> URL
    /// The file whose write makes the guest simulate a memory warning.
    func memoryWarningFile() throws -> URL
    /// Whether a Core Animation debug option is on. CoreSimulator drops the
    /// error of this read, so false can also mean that it failed.
    func caDebugOption(_ option: CADebugOption) throws -> Bool
    /// CoreSimulator drops the error of this change.
    func setCADebugOption(_ option: CADebugOption, enabled: Bool) throws
    // Location calls run off the main actor and reach the device in the
    // order they are made.
    /// The runtime's recorded location routes, in CoreSimulator's order.
    func locationScenarios() async throws -> [LocationScenario]
    func clearSimulatedLocation() async throws
    func setLocation(latitude: Double, longitude: Double) async throws
    /// Runs the route a `LocationScenario.name` names.
    func setLocationScenario(_ name: String) async throws
    // Keyboard calls run off the main actor and reach the device in the
    // order they are made.
    /// Connects or disconnects the guest's hardware keyboard, of the Mac
    /// keyboard's type.
    func setHardwareKeyboardConnected(_ connected: Bool) async throws
    /// Sets the language of the guest's keyboard, such as `en` or `ja`.
    func setKeyboardLanguage(_ language: String) async throws
    /// Connects to the device's pasteboard service, managing `pasteboard`;
    /// `events` receives the connection's callbacks.
    func connectPasteboard(_ pasteboard: NSPasteboard,
                           events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) throws -> any SimulatorPasteboard
    func setChromeVisible(_ visible: Bool)
    func setActive(_ active: Bool)
    func setKeyboardEnabled(_ enabled: Bool)
    /// `SimDigitizerInputView.supportTouchPressure`: whether clicks press
    /// the screen with a pressure.
    func setSupportsTouchPressure(_ supports: Bool)
    /// `SimDigitizerInputView.useForceTrackpadForPressure`: whether the
    /// pressure follows the force on a Force Touch trackpad.
    func setUsesTrackpadForce(_ uses: Bool)
    /// `SimDigitizerInputView.simulatedTouchMode`.
    func setSimulatedTouchMode(_ mode: SimulatedTouchMode)
    /// Adds `indicator`'s `DrawOption` to `SimDigitizerInputView.drawOptions`
    /// or removes it, keeping the other options.
    func setTouchIndicator(_ indicator: TouchIndicator, shown: Bool)
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

    var renderScale: CGFloat {
        read("read the display scale", otherwise: 0) { try unsafe runtime.display.renderScale.unsafeInvoke(on: view) }
    }

    func setRenderScale(_ scale: CGFloat) {
        perform("scale the display") { try unsafe runtime.display.setRenderScale.unsafeInvoke(on: view, scale) }
        view.invalidateIntrinsicContentSize()
    }

    func size(for scale: CGFloat) -> NSSize {
        read("measure the display", otherwise: .zero) { try unsafe runtime.display.sizeForScale.unsafeInvoke(on: view, scale) }
    }

    func scale(for size: NSSize) -> CGFloat {
        read("measure the display", otherwise: 0) { try unsafe runtime.display.scaleForSize.unsafeInvoke(on: view, size) }
    }

    var screenScale: CGFloat? {
        read("read the screen scale", otherwise: nil) { try unsafe runtime.display.screenScale.unsafeInvoke(on: screen) }
    }

    var displayClass: UInt16? {
        read("read the display class", otherwise: nil) { try unsafe runtime.display.displayClass.unsafeInvoke(on: screen) }
    }

    var chromePadding: NSSize? {
        let display = runtime.display
        return read("read the device bezel", otherwise: nil) {
            guard let chrome = try unsafe display.chrome.unsafeInvoke(on: chromeView)
                .resolveEnumPayloadAndWait(forCase: "some") else { return nil }
            return try unsafe display.chromeImagesPadding.unsafeInvoke(on: display.chromeImages.unsafeInvoke(on: chrome))
        }
    }

    var resizeRects: [DisplayResizeRect] {
        let display = runtime.display
        return read("read the bezel's resize corners", otherwise: []) {
            let rects = try unsafe display.resizeRects.unsafeInvoke(on: view)
            var result: [DisplayResizeRect] = []
            for index in 0..<(try unsafe display.resizeRectCount.unsafeInvoke(on: rects)) {
                let rect = try unsafe display.resizeRectAtIndex.unsafeInvoke(on: rects, index)
                let type = try unsafe display.resizeRectTypeName.unsafeInvoke(on: display.resizeRectType.unsafeInvoke(on: rect))
                // A corner type that this host does not know resizes nothing.
                guard let corner = DisplayResizeRect.Corner(rawValue: type) else { continue }
                result.append(DisplayResizeRect(corner: corner, rect: try unsafe display.resizeRectFrame.unsafeInvoke(on: rect)))
            }
            return result
        }
    }

    func setShowsResizeCursors(_ shows: Bool) {
        perform("show resize cursors") { try unsafe runtime.display.showResizeCursors.unsafeInvoke(on: view, shows) }
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
    func logDirectory() throws -> URL { try device.logDirectory() }
    func memoryWarningFile() throws -> URL { try device.memoryWarningFile() }
    func caDebugOption(_ option: CADebugOption) throws -> Bool { try device.caDebugOption(option) }
    func setCADebugOption(_ option: CADebugOption, enabled: Bool) throws {
        try device.setCADebugOption(option, enabled: enabled)
    }
    func locationScenarios() async throws -> [LocationScenario] { try await device.locationScenarios() }
    func clearSimulatedLocation() async throws { try await device.clearSimulatedLocation() }
    func setLocation(latitude: Double, longitude: Double) async throws {
        try await device.setLocation(latitude: latitude, longitude: longitude)
    }
    func setLocationScenario(_ name: String) async throws { try await device.setLocationScenario(name) }
    func setHardwareKeyboardConnected(_ connected: Bool) async throws {
        try await device.setHardwareKeyboardEnabled(connected, keyboardType: runtime.input.currentKeyboardType())
    }
    func setKeyboardLanguage(_ language: String) async throws { try await device.setKeyboardLanguage(language) }
    func connectPasteboard(_ pasteboard: NSPasteboard,
                           events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) throws -> any SimulatorPasteboard {
        try runtime.pasteboard.connect(to: device, managing: pasteboard, events: events)
    }
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
    func setSupportsTouchPressure(_ supports: Bool) {
        guard !disconnected else { return }
        perform("enable touch pressure") {
            try unsafe runtime.display.setSupportsTouchPressure.unsafeInvoke(on: inputView, supports)
        }
    }
    func setUsesTrackpadForce(_ uses: Bool) {
        guard !disconnected else { return }
        perform("use the trackpad's force") {
            try unsafe runtime.display.setUsesTrackpadForce.unsafeInvoke(on: inputView, uses)
        }
    }
    func setSimulatedTouchMode(_ mode: SimulatedTouchMode) {
        guard !disconnected else { return }
        perform("set the touch pressure") {
            try unsafe runtime.display.setSimulatedTouchMode.unsafeInvoke(on: inputView, mode.rawValue)
        }
    }
    func setTouchIndicator(_ indicator: TouchIndicator, shown: Bool) {
        guard !disconnected else { return }
        let display = runtime.display
        perform("show touch indicators") {
            let options = try unsafe display.drawOptionRawValue.unsafeInvoke(on: display.drawOptions.unsafeInvoke(on: inputView))
            let option = display.drawOption(for: indicator)
            try unsafe display.setDrawOptions.unsafeInvoke(
                on: inputView, display.makeDrawOption.unsafeInvoke(shown ? options | option : options & ~option))
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
        read(operation, otherwise: (), body)
    }

    private func read<Value>(_ operation: String, otherwise fallback: Value, _ body: () throws -> Value) -> Value {
        do { return try body() } catch {
            hostLog("Could not \(operation): \(error.localizedDescription)")
            return fallback
        }
    }
}
