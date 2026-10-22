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
    let audio: SimulatorAudioInterface

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
        audio = try SimulatorAudioInterface(runtime: runtime)
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

    /// Checks the images loaded so far, also those that SimulatorKit loads
    /// when it connects a display, such as a device type's user-interface
    /// plugin (`.simdeviceui`), which must come from the selected Xcode.
    func validateLoadedImages() throws {
        let prefix = xcodeURL.path + "/"
        for index in 0..<_dyld_image_count() {
            guard let pointer = _dyld_get_image_name(index) else { continue }
            let path = URL(fileURLWithPath: String(cString: pointer)).resolvingSymlinksInPath().path
            if path.contains("/DeviceKit.framework/") || path.contains("/DeviceHub.app/") {
                throw HostError.unavailable("Forbidden Device Hub component is loaded: \(path)")
            }
            if (path.contains("/SimulatorKit.framework/") || path.contains("/IDEPlaygroundSimulator.framework/")
                || path.contains(".simdeviceui/")), !path.hasPrefix(prefix) {
                throw HostError.unavailable("Private simulator code came from a different Xcode: \(path)")
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
    /// `SimDevice.screenAdapter`, the device's `SimDeviceScreenAdapter`.
    let screenAdapter = ScreenAdapterGetter()
    /// `SimDeviceScreenAdapter.screens`, a `[UInt32: SimDeviceScreen]` by screen ID.
    let adapterScreens: NativeSwiftMethod<() -> NativeSwiftValue>
    /// Messages to CoreSimDeviceIO's screen proxies: `SimScreenProperties`
    /// and `SimScreenMode`.
    let screenMessages = ProxyMessages()
    /// The properties of Simulator.app's default CarPlay configuration, by
    /// CoreSimDeviceIO's `SimCarPlayPropertyKeyStark` and
    /// `SimCarPlayPropertyKeyHasTouchScreen`: a CarPlay screen with a touch
    /// screen.
    let carPlayProperties: NSDictionary
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
    /// `SimDisplayView._userInterfacePlugin`: the `SimDeviceUserInterfacePlugin`
    /// that the display loads, while it connects, for a device type with a
    /// user-interface profile, such as Apple Vision Pro's `XROS.simdeviceui`.
    /// SimulatorKit has no getter for it; the field holds one object.
    let userInterfacePlugin: Ivar
    /// Messages to a plugin, whose class its bundle provides only once loaded;
    /// `SimDeviceUserInterfacePlugin` must declare them.
    let pluginMessages = ProxyMessages()
    /// `SimDigitizerInputView.supportScrolling`.
    let setSupportsScrolling: NativeSwiftMethod<(Bool) -> Void>
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
        // SimulatorKit does not export the descriptors of the imported C types
        // these getters return, so the host integers state their conventions.
        let uint32 = try runtime.resolveSwiftTypeAndWait(named: "Swift.UInt32")
        let uint16 = try runtime.resolveSwiftTypeAndWait(named: "Swift.UInt16")
        buttonTarget = try deviceScreen.resolveGetterAndWait(
            named: "buttonTarget.getter : __C.IndigoHIDTarget", as: (() -> UInt32).self,
            valueABIs: [uint32: .uint32])
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
            named: "displayClass.getter : __C.SimDisplayClass", as: (() -> UInt16).self,
            valueABIs: [uint16: .uint16])
        registerScreenEvents = try deviceScreen.resolveMethodAndWait(
            named: "register(types:queue:handler:)",
            as: ((NativeSwiftValue, DispatchQueue, ScreenEventHandler) -> NativeSwiftValue).self,
            valueABIs: eventABIs)
        // Swift's Dictionary is a single reference.
        let screensByID = try runtime.resolveSwiftTypeAndWait(
            named: "Swift.Dictionary",
            genericArguments: [.type(try runtime.resolveSwiftTypeAndWait(named: "Swift.UInt32")), .type(deviceScreen)])
        adapterScreens = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDeviceScreenAdapter")
            .resolveGetterAndWait(named: "screens", as: (() -> NativeSwiftValue).self,
                                  valueABIs: [screensByID: try .structure(named: "Dictionary", fields: [.pointer])])
        // The screens and their properties are proxies, so these messages are
        // bound to each proxy class when a screen connects; their protocols
        // must declare them.
        for (name, selectors) in SimulatorExternalScreenConnection.selectors + SimulatorConnection.backlightSelectors {
            guard let declared = objc_getProtocol(name) else {
                throw HostError.unavailable("Required private protocol \(name) is unavailable")
            }
            for selector in selectors
            where unsafe protocol_getMethodDescription(declared, NSSelectorFromString(selector), true, true).name == nil {
                throw HostError.unavailable("\(name) does not declare \(selector)")
            }
        }
        func carPlayKey(_ name: String) throws -> String {
            let symbol = try runtime.resolveAndWait(NativeDeclaration(name: name, language: .c, kind: .data))
            guard let key = unsafe symbol.withUnsafeAddress({
                unsafe $0.load(as: Unmanaged<NSString>?.self)?.takeUnretainedValue() as String?
            }) else {
                throw HostError.unavailable("\(name) has no value")
            }
            return key
        }
        carPlayProperties = [try carPlayKey("SimCarPlayPropertyKeyStark"): true,
                             try carPlayKey("SimCarPlayPropertyKeyHasTouchScreen"): true]
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
        guard let userInterfacePlugin = class_getInstanceVariable(displayViewClass, "_userInterfacePlugin") else {
            throw HostError.unavailable("\(displayViewClass) does not provide _userInterfacePlugin")
        }
        self.userInterfacePlugin = userInterfacePlugin
        let pluginProtocol = "_TtP12SimulatorKit28SimDeviceUserInterfacePlugin_"
        guard let declared = objc_getProtocol(pluginProtocol) else {
            throw HostError.unavailable("Required private protocol \(pluginProtocol) is unavailable")
        }
        for selector in SimulatorUserInterfacePlugin.selectors
        where unsafe protocol_getMethodDescription(declared, NSSelectorFromString(selector), true, true).name == nil {
            throw HostError.unavailable("\(pluginProtocol) does not declare \(selector)")
        }
        let digitizer = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDigitizerInputView")
        setSupportsScrolling = try digitizer.resolveSetterAndWait(named: "supportScrolling", as: Bool.self)
        setSupportsTouchPressure = try digitizer.resolveSetterAndWait(named: "supportTouchPressure", as: Bool.self)
        setUsesTrackpadForce = try digitizer.resolveSetterAndWait(named: "useForceTrackpadForPressure", as: Bool.self)
        // TouchMode has no field metadata to establish its convention.
        let touchMode = try runtime.resolveSwiftTypeAndWait(named: "SimulatorKit.SimDigitizerInputView.TouchMode")
        setSimulatedTouchMode = try digitizer.resolveSetterAndWait(
            named: "simulatedTouchMode.setter : SimulatorKit.SimDigitizerInputView.TouchMode", as: Int.self,
            valueABIs: [touchMode: .int])
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

    /// `SimScreenType`'s TVOut, the external display that I/O ▸ External
    /// Displays configures. 0 is a device's own screen and 2 is CarPlay.
    static let externalScreenType: UInt64 = 1

    /// The device's external display: of the screens its screen adapter
    /// lists, the first by ID that is connected and of the TVOut type, as
    /// Simulator.app waits for one. Nil for a device without one.
    func externalScreen(of device: SimulatorDevice) throws -> (identifier: UInt32, object: AnyObject)? {
        guard let adapter = try screenAdapter.adapter(of: device.object) else { return nil }
        let value = try unsafe adapterScreens.unsafeInvoke(on: adapter)
        guard let screens = try value.withCopy({ $0 as? [UInt32: AnyObject] }) else {
            throw HostError.unavailable("SimulatorKit listed the device's screens as \(value.type.name)")
        }
        for (identifier, screen) in screens.sorted(by: { $0.key < $1.key }) {
            guard try unsafe self.screen.unsafeInvoke(on: screen) != nil,
                  try screenMessages.send("screenType", to: unsafe screenProperties.unsafeInvoke(on: screen),
                                          as: UInt64.self) == Self.externalScreenType else { continue }
            return (identifier, screen)
        }
        return nil
    }
}

/// `SimDevice.screenAdapter`, which SimulatorKit declares in an extension of
/// the Objective-C class `SimDevice`. ABIBridge finds such a member only
/// through an instance, so it is bound to the first device that asks for its
/// adapter and reused for the others.
@MainActor
final class ScreenAdapterGetter {
    private var getter: NativeSwiftMethod<() -> AnyObject?>?

    /// The device's `SimDeviceScreenAdapter`, which SimulatorKit keeps for
    /// the device's lifetime, or nil when it has none.
    func adapter(of device: AnyObject) throws -> AnyObject? {
        let getter = try self.getter ?? ABIRuntime.shared.object(device).resolveGetterAndWait(
            named: "(extension in SimulatorKit):__C.SimDevice.screenAdapter.getter : SimulatorKit.SimDeviceScreenAdapter?",
            as: (() -> AnyObject?).self).method
        self.getter = getter
        return try unsafe getter.unsafeInvoke(on: device)
    }
}

/// Messages without arguments to objects whose classes exist only at run
/// time, such as CoreSimDeviceIO's proxies of screen properties and modes,
/// and a device type's user-interface plugin. A message is bound to the first
/// object of a class that receives it and reused for the others.
@MainActor
final class ProxyMessages {
    private var methods: [String: Any] = [:]

    func send<Result>(_ selector: String, to object: AnyObject, as type: Result.Type = Result.self) throws -> Result {
        let key = "\(ObjectIdentifier(Swift.type(of: object))) \(selector)"
        let method = try methods[key] as? NativeObjCMethod<Result> ?? ABIRuntime.shared.object(object)
            .resolveMethodAndWait(selector: selector, as: (() -> Result).self).method
        methods[key] = method
        return try unsafe method.unsafeInvoke(on: object)
    }
}

/// The user-interface plugin that SimulatorKit attached to a display, a
/// `SimDeviceUserInterfacePlugin` from the selected Xcode's profile of the
/// device type, such as Apple Vision Pro's `XROS.simdeviceui`, whose
/// principal class is `PalomaSimSupport`. The display adds the plugin's
/// overlay over its screen; the overlay takes the device's input and handles
/// the plugin's commands. Simulator.app shows the plugin's toolbar in the
/// device's window.
struct SimulatorUserInterfacePlugin {
    /// The messages the host sends to a plugin.
    static let selectors = ["overlayView", "toolbar"]

    let overlayView: NSView?
    let toolbar: NSToolbar?
}

/// A device's external display: CoreSimulator's TVOut screen, which a device
/// that supports external displays has from its creation, turned off.
/// CoreSimDeviceIO's screen adapter lists no screen that a client could
/// create (`creatableScreenProperties` is empty), so a device without one
/// cannot get one. Simulator.app also makes this screen the device's CarPlay
/// display, so the connection also reaches the guest's CarPlay.
@MainActor
protocol SimulatorExternalScreen: AnyObject {
    var screenID: UInt32 { get }
    /// When the device last booted. The guest's CarPlay session belongs to
    /// the boot that started it.
    var deviceBootDate: Date? { get }
    /// The screen's power, size, scale, and CarPlay as CoreSimulator reports them now.
    func state() throws -> ExternalScreenState
    /// `SimScreen setCurrentMode:pixelSize:carPlayProperties:…` with the mode
    /// Simulator.app chooses for `pixelSize` at `scale`, which also turns the
    /// screen on. With `carPlay`, the properties of Simulator.app's default
    /// CarPlay configuration (`SimCarPlayPropertyKeyStark` and
    /// `SimCarPlayPropertyKeyHasTouchScreen`) make it a CarPlay screen;
    /// without, it has none. `completion` receives CoreSimulator's result on
    /// the main actor; a thrown error, such as for a size that no mode takes,
    /// means nothing was sent.
    func setMode(pixelSize: CGSize, scale: CGFloat, carPlay: Bool,
                 completion: @escaping @MainActor (Error?) -> Void) throws
    /// `SimScreen setPowerState:0 …`. `completion` receives CoreSimulator's
    /// result on the main actor; a thrown error means nothing was sent.
    func powerOff(completion: @escaping @MainActor (Error?) -> Void) throws
    /// Writes the device's `extended_display.plist`, which the guest reads
    /// each time the screen's modes change: Simulator.app's default CarPlay
    /// configuration with `carPlay`, which makes the guest take the screen as
    /// a car's display, and `{stark: 0}` otherwise.
    func saveCarPlayConfiguration(carPlay: Bool) throws
    /// `SimDevice enableCarPlay:error:`, which starts or ends a CarPlay
    /// session in the guest. The guest counts them, so each start needs one
    /// end. The request is decided for the device's `boot`; a device that has
    /// restarted since gets nothing, and `completion` receives
    /// `CarPlayRequestMoot`. Otherwise it receives the result, on the main
    /// actor.
    func setCarPlayEnabled(_ enabled: Bool, inBoot boot: Date?, completion: @escaping @MainActor (Error?) -> Void)
    /// Creates the guest's CarPlay HID service, which takes the touches of
    /// the screen's display, or removes it. `completion` receives the send's
    /// result on the main actor; a thrown error means nothing was sent.
    func setCarPlayService(connected: Bool, completion: @escaping @MainActor (Error?) -> Void) throws
    /// A display of the screen from the display factory, for its own window.
    func makeDisplay() throws -> any SimulatorDisplay
    /// Stops the change reports.
    func disconnect()
}

/// A CarPlay request that was not sent because the device restarted after it
/// was decided for the device's earlier boot.
struct CarPlayRequestMoot: Error {}

/// The external display of one device, through SimulatorKit's
/// `SimDeviceScreen` and CoreSimDeviceIO's `SimScreen`.
@MainActor
final class SimulatorExternalScreenConnection: SimulatorExternalScreen {
    /// The messages this connection sends to proxies, by protocol.
    static let selectors = [
        ("SimScreen", ["setCurrentMode:pixelSize:carPlayProperties:completionQueue:completionHandler:",
                       "setPowerState:completionQueue:completionHandler:", "screenProperties"]),
        ("SimScreenProperties", ["powerState", "screenType", "pixelSize", "currentMode", "supportedScreenModes",
                                 "carPlayProperties"]),
        ("SimScreenMode", ["sizeRule", "exactSize", "minSize", "maxSize", "allowedSizes", "preferredUIScale"]),
    ]

    typealias Completion = @convention(block) (NSError?) -> Void

    let screenID: UInt32
    private let device: SimulatorDevice
    /// The `SimDeviceScreen`.
    private let screen: AnyObject
    private let runtime: SimulatorRuntime
    private let setCurrentMode: NativeObjCMethod<Void, AnyObject, CGSize, NSDictionary?, DispatchQueue, Completion>
    private let setPowerState: NativeObjCMethod<Void, Int32, DispatchQueue, Completion>
    private var events: NativeSwiftValue?
    /// The HID client that sends the CarPlay service's messages, from the first.
    private var hidClient: AnyObject?

    init(device: SimulatorDevice, screen: (identifier: UInt32, object: AnyObject), runtime: SimulatorRuntime,
         changed: @escaping @MainActor () -> Void) throws {
        self.device = device
        self.screen = screen.object
        self.runtime = runtime
        screenID = screen.identifier
        let display = runtime.display
        guard let simScreen = try unsafe display.screen.unsafeInvoke(on: screen.object) else {
            throw HostError.unavailable("The external display is not connected.")
        }
        // Every screen of a device is a proxy of one class.
        let proxy = ABIRuntime.shared.object(simScreen)
        setCurrentMode = try proxy.resolveMethodAndWait(
            selector: "setCurrentMode:pixelSize:carPlayProperties:completionQueue:completionHandler:",
            as: ((AnyObject, CGSize, NSDictionary?, DispatchQueue, @escaping Completion) -> Void).self).method
        setPowerState = try proxy.resolveMethodAndWait(
            selector: "setPowerState:completionQueue:completionHandler:",
            as: ((Int32, DispatchQueue, @escaping Completion) -> Void).self).method
        let handler = try SimulatorDisplayInterface.ScreenEventHandler { _, _ in
            MainActor.assumeIsolated { changed() }
        }
        events = try unsafe display.registerScreenEvents.unsafeInvoke(
            on: screen.object, display.screenPropertyEvents, .main, handler)
    }

    isolated deinit { disconnect() }

    var deviceBootDate: Date? { device.lastBootDate }

    func state() throws -> ExternalScreenState {
        let messages = runtime.display.screenMessages
        let properties = try self.properties()
        let currentMode = try messages.send("currentMode", to: properties, as: AnyObject?.self)
        return ExternalScreenState(
            isPoweredOn: try messages.send("powerState", to: properties, as: Int32.self) == 1,
            pixelSize: try messages.send("pixelSize", to: properties, as: CGSize.self),
            scale: try currentMode.map { CGFloat(try messages.send("preferredUIScale", to: $0, as: Double.self)) } ?? 0,
            isCarPlay: try messages.send("carPlayProperties", to: properties, as: NSDictionary?.self) != nil)
    }

    func setMode(pixelSize size: CGSize, scale: CGFloat, carPlay: Bool,
                 completion: @escaping @MainActor (Error?) -> Void) throws {
        let simScreen = try connectedScreen()
        let messages = runtime.display.screenMessages
        let properties = try self.properties()
        let advertised = try messages.send("supportedScreenModes", to: properties, as: [AnyObject]?.self) ?? []
        let current = try state()
        let modes = try advertised.map(mode)
        let target: AnyObject?
        switch ExternalScreenMode.choice(for: size, scale: scale, currentSize: current.pixelSize,
                                         currentScale: current.scale, among: modes) {
        case .current: target = try messages.send("currentMode", to: properties, as: AnyObject?.self)
        case .advertised(let index): target = advertised[index]
        case nil: target = nil
        }
        guard let target else {
            throw HostError.operation("The external display has no mode for \(Int(size.width))×\(Int(size.height)) at a scale of \(scale).")
        }
        try unsafe setCurrentMode.unsafeInvoke(on: simScreen, target, size,
                                               carPlay ? runtime.display.carPlayProperties : nil, .main,
                                               Self.completed(completion))
    }

    func powerOff(completion: @escaping @MainActor (Error?) -> Void) throws {
        try unsafe setPowerState.unsafeInvoke(on: connectedScreen(), 0, .main, Self.completed(completion))
    }

    func saveCarPlayConfiguration(carPlay: Bool) throws {
        try CarPlayConfiguration.save(carPlay: carPlay, to: device.extendedDisplayFile())
    }

    func setCarPlayEnabled(_ enabled: Bool, inBoot boot: Date?, completion: @escaping @MainActor (Error?) -> Void) {
        Task { [device] in
            do {
                try await device.setCarPlayEnabled(enabled, inBoot: boot)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func setCarPlayService(connected: Bool, completion: @escaping @MainActor (Error?) -> Void) throws {
        let client = try hidClient ?? runtime.input.connect(to: device)
        hidClient = client
        try runtime.input.sendCarPlayService(connected: connected, hasTouchScreen: CarPlayConfiguration.hasTouchScreen,
                                             client: client, completion: completion)
    }

    func makeDisplay() throws -> any SimulatorDisplay {
        try SimulatorConnection(device: device, screen: (screenID, screen), runtime: runtime)
    }

    func disconnect() {
        // Releasing the registration ends the screen events.
        events = nil
    }

    private func properties() throws -> AnyObject {
        try unsafe runtime.display.screenProperties.unsafeInvoke(on: screen)
    }

    private func connectedScreen() throws -> AnyObject {
        guard let simScreen = try unsafe runtime.display.screen.unsafeInvoke(on: screen) else {
            throw HostError.unavailable("The external display is not connected.")
        }
        return simScreen
    }

    /// A `SimScreenMode`, read as Simulator.app's mode choice reads it.
    private func mode(_ object: AnyObject) throws -> ExternalScreenMode {
        let messages = runtime.display.screenMessages
        let sizes: ExternalScreenMode.Sizes? = switch try messages.send("sizeRule", to: object, as: UInt64.self) {
        case 0: .exact(try messages.send("exactSize", to: object, as: CGSize.self))
        case 1: .range(minimum: try messages.send("minSize", to: object, as: CGSize.self),
                       maximum: try messages.send("maxSize", to: object, as: CGSize.self))
        case 2: .allowed((try messages.send("allowedSizes", to: object, as: [NSValue]?.self) ?? []).map(\.sizeValue))
        default: nil
        }
        return ExternalScreenMode(sizes: sizes,
                                  scale: CGFloat(try messages.send("preferredUIScale", to: object, as: Double.self)))
    }

    // CoreSimDeviceIO can complete on a thread of its own despite the
    // completion queue, so the block is built outside the main actor and
    // passes the result on to the main queue.
    private nonisolated static func completed(_ completion: @escaping @MainActor (Error?) -> Void) -> Completion {
        { error in DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } } }
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
    /// `IndigoHIDMessageForWatchGesture(gesture)`.
    let messageForWatchGesture: NativeFunction<OpaquePointer?, UInt32>
    /// `IndigoHIDGetKeyboardType()`, the type of the Mac's keyboard.
    let keyboardType: NativeFunction<UInt32>
    /// `IndigoHIDMessageToCreateCarPlayService(hasDigitizer)` and
    /// `IndigoHIDMessageToRemoveCarPlayService()`: the guest's HID service for
    /// CarPlay, at the target that SimulatorKit's display of an external
    /// display sends its touches to.
    let createCarPlayService: NativeFunction<OpaquePointer?, Bool>
    let removeCarPlayService: NativeFunction<OpaquePointer?>

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
        messageForWatchGesture = try runtime.resolveCFunctionAndWait(
            named: "IndigoHIDMessageForWatchGesture", as: ((UInt32) -> OpaquePointer?).self)
        keyboardType = try runtime.resolveCFunctionAndWait(named: "IndigoHIDGetKeyboardType", as: (() -> UInt32).self)
        createCarPlayService = try runtime.resolveCFunctionAndWait(
            named: "IndigoHIDMessageToCreateCarPlayService", as: ((Bool) -> OpaquePointer?).self)
        removeCarPlayService = try runtime.resolveCFunctionAndWait(
            named: "IndigoHIDMessageToRemoveCarPlayService", as: (() -> OpaquePointer?).self)
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
        try send(hidMessage.take(), client: client, completion: completion)
    }

    /// Sends a watch gesture, a single message without down and up events.
    func send(_ gesture: WatchGesture, client: AnyObject, completion: @escaping @MainActor (Error?) -> Void) throws {
        guard let message = try unsafe messageForWatchGesture.unsafeInvoke(gesture.rawValue) else {
            throw HostError.operation("Could not allocate simulator input")
        }
        try send(message, client: client, completion: completion)
    }

    /// Sends the message that creates the guest's CarPlay HID service, with a
    /// digitizer for a touch screen, or the one that removes it. SimulatorKit
    /// reports the send's result, not the guest's, to `completion` on the
    /// main queue. The guest creates the service only once.
    func sendCarPlayService(connected: Bool, hasTouchScreen: Bool, client: AnyObject,
                            completion: @escaping @MainActor (Error?) -> Void) throws {
        let message = try unsafe connected ? createCarPlayService.unsafeInvoke(hasTouchScreen)
                                           : removeCarPlayService.unsafeInvoke()
        guard let message else { throw HostError.operation("Could not allocate simulator input") }
        try send(message, client: client, completion: completion)
    }

    private func send(_ message: OpaquePointer, client: AnyObject, completion: (@MainActor (Error?) -> Void)?) throws {
        // The send transfers ownership of the message to SimulatorKit.
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

/// CoreSimDeviceIO's audio route port: the descriptor of a device's I/O port
/// that conforms to `SimAudioHostRoutable`. Simulator.app reaches it through
/// SimulatorKit's `SimDeviceAudioClient`, which Xcode 27 removed, and
/// `devicectl device settings audio` through CoreDevice's simulator plugin.
/// Unlike `devicectl`, it reaches devices of any device set.
@MainActor
struct SimulatorAudioInterface {
    /// `SimDevice.io`, the device's `SimDeviceIOClient`.
    let deviceIO: NativeObjCMethod<AnyObject?>
    /// `SimDeviceIOClient.ioPorts`, remote proxies of the device's I/O ports.
    let ioPorts: NativeObjCMethod<[AnyObject]>
    let routable: Protocol

    typealias DevicesChanged = @convention(block) (NSArray?) -> Void
    typealias RouteChanged = @convention(block) (UInt64, NSString?) -> Void
    typealias RouteCompletion = @convention(block) (NSError?) -> Void

    init(runtime: ABIRuntime) throws {
        guard let device = NSClassFromString("SimDevice"), let client = NSClassFromString("SimDeviceIOClient") else {
            throw HostError.unavailable("CoreSimulator's device I/O classes are unavailable")
        }
        deviceIO = try runtime.resolveObjCMethodAndWait(on: device, selector: "io", as: (() -> AnyObject?).self)
        ioPorts = try runtime.resolveObjCMethodAndWait(on: client, selector: "ioPorts", as: (() -> [AnyObject]).self)
        // The port and its Mac devices are remote proxies, so their messages
        // are bound to each object when a device connects; their protocols
        // must declare them.
        let protocols = [("SimAudioHostRoutable", SimulatorAudioConnection.portSelectors),
                         ("SimAudioHostDevice", HostAudioDeviceMembers.selectors)]
        for (name, selectors) in protocols {
            guard let declared = objc_getProtocol(name) else {
                throw HostError.unavailable("Required private protocol \(name) is unavailable")
            }
            for selector in selectors
            where unsafe protocol_getMethodDescription(declared, NSSelectorFromString(selector), true, true).name == nil {
                throw HostError.unavailable("\(name) does not declare \(selector)")
            }
        }
        guard let routable = objc_getProtocol("SimAudioHostRoutable") else {
            throw HostError.unavailable("Required private protocol SimAudioHostRoutable is unavailable")
        }
        self.routable = routable
        // Recent routes are saved with this value, so it must not change.
        let symbol = try runtime.resolveAndWait(NativeDeclaration(
            name: "SimAudioHostUseSystemDefaultDeviceUID", language: .c, kind: .data))
        let systemDefault = unsafe symbol.withUnsafeAddress {
            unsafe $0.load(as: Unmanaged<NSString>?.self)?.takeUnretainedValue() as String?
        }
        guard systemDefault == AudioRouting.systemDefault else {
            throw HostError.unavailable("SimAudioHostUseSystemDefaultDeviceUID is \(systemDefault ?? "nil")")
        }
    }

    /// Connects to the device's audio route port, which a booted device that
    /// has `SimFeatureRoutableAudio` provides.
    func connect(to device: SimulatorDevice,
                 changed: @escaping @MainActor () -> Void) throws -> SimulatorAudioConnection {
        guard let io = try unsafe deviceIO.unsafeInvoke(on: device.object) else {
            throw HostError.unavailable("The device did not provide its I/O ports.")
        }
        var descriptor: NativeObjCMethod<AnyObject?>?
        for port in try unsafe ioPorts.unsafeInvoke(on: io) {
            // Every port is a proxy of one class.
            let method = try descriptor ?? ABIRuntime.shared.object(port)
                .resolveMethodAndWait(selector: "descriptor", as: (() -> AnyObject?).self).method
            descriptor = method
            if let object = try unsafe method.unsafeInvoke(on: port),
               (object as? NSObjectProtocol)?.conforms(to: routable) == true {
                return try SimulatorAudioConnection(port: object, changed: changed)
            }
        }
        throw HostError.unavailable("The device has no audio route port.")
    }
}

/// A device's audio routes: CoreSimDeviceIO's `SimAudioHostRoutable`.
@MainActor
protocol SimulatorAudioRoutes: AnyObject {
    /// The Mac's audio devices and the guest's routes as the port reports them now.
    func state() throws -> AudioRouteState
    /// Routes the guest's `scope` to a Mac device's unique identifier or to
    /// `AudioRouting.systemDefault`. `completion` receives CoreSimulator's
    /// result on the main actor; a thrown error means nothing was sent.
    ///
    /// CoreSimulator does not fail a route to a device that the Mac lacks or
    /// that has no channels in `scope`: it routes the guest to the Mac's
    /// default device, by that device's identifier.
    func route(_ scope: AudioScope, to route: String, completion: @escaping @MainActor (Error?) -> Void) throws
    /// Stops the change reports.
    func disconnect()
}

/// The audio route port of one device. It reports a change of the Mac's
/// devices, including its default devices, and of the guest's routes, also
/// those that another process makes.
@MainActor
final class SimulatorAudioConnection: SimulatorAudioRoutes {
    static let portSelectors = [
        "availableHostDevices", "guestInputHostDeviceUID", "guestOutputHostDeviceUID",
        "effectiveDefaultInputDeviceUID", "effectiveDefaultOutputDeviceUID",
        "routeGuestDeviceScope:toHostDeviceUID:completionQueue:completionHandler:",
        "registerCallbackWithUUID:availableDevicesChangedCallback:",
        "registerCallbackWithUUID:selectedDeviceUIDChangedCallback:", "unregisterCallbackWithUUID:",
    ]

    private let availableDevices: NativeBoundObjCMethod<[AnyObject]?>
    private let inputRoute: NativeBoundObjCMethod<String?>
    private let outputRoute: NativeBoundObjCMethod<String?>
    private let defaultInput: NativeBoundObjCMethod<String?>
    private let defaultOutput: NativeBoundObjCMethod<String?>
    private let routeGuest: NativeBoundObjCMethod<Void, UInt64, String, DispatchQueue,
                                                  SimulatorAudioInterface.RouteCompletion>
    private let unregister: NativeBoundObjCMethod<Void, NSUUID>
    /// Identifies this connection's change reports.
    private let token = NSUUID()
    private var members: HostAudioDeviceMembers?
    private var isConnected = true

    fileprivate init(port: AnyObject, changed: @escaping @MainActor () -> Void) throws {
        let object = ABIRuntime.shared.object(port)
        availableDevices = try object.resolveMethodAndWait(
            selector: "availableHostDevices", as: (() -> [AnyObject]?).self)
        inputRoute = try object.resolveMethodAndWait(selector: "guestInputHostDeviceUID", as: (() -> String?).self)
        outputRoute = try object.resolveMethodAndWait(selector: "guestOutputHostDeviceUID", as: (() -> String?).self)
        defaultInput = try object.resolveMethodAndWait(
            selector: "effectiveDefaultInputDeviceUID", as: (() -> String?).self)
        defaultOutput = try object.resolveMethodAndWait(
            selector: "effectiveDefaultOutputDeviceUID", as: (() -> String?).self)
        routeGuest = try object.resolveMethodAndWait(
            selector: "routeGuestDeviceScope:toHostDeviceUID:completionQueue:completionHandler:",
            as: ((UInt64, String, DispatchQueue, @escaping SimulatorAudioInterface.RouteCompletion) -> Void).self)
        unregister = try object.resolveMethodAndWait(selector: "unregisterCallbackWithUUID:", as: ((NSUUID) -> Void).self)
        let registerDevices = try object.resolveMethodAndWait(
            selector: "registerCallbackWithUUID:availableDevicesChangedCallback:",
            as: ((NSUUID, @escaping SimulatorAudioInterface.DevicesChanged) -> Void).self)
        let registerRoutes = try object.resolveMethodAndWait(
            selector: "registerCallbackWithUUID:selectedDeviceUIDChangedCallback:",
            as: ((NSUUID, @escaping SimulatorAudioInterface.RouteChanged) -> Void).self)
        try unsafe registerDevices.unsafeInvoke(token, Self.devicesChanged(changed))
        do {
            try unsafe registerRoutes.unsafeInvoke(token, Self.routeChanged(changed))
        } catch {
            disconnect()
            throw error
        }
    }

    isolated deinit { disconnect() }

    // The port calls these blocks, and a route's completion despite its
    // completion queue, on threads of its own, so they are built outside the
    // main actor and pass the call on to the main queue.
    private nonisolated static func devicesChanged(
        _ changed: @escaping @MainActor () -> Void
    ) -> SimulatorAudioInterface.DevicesChanged {
        { _ in DispatchQueue.main.async { MainActor.assumeIsolated { changed() } } }
    }

    private nonisolated static func routeChanged(
        _ changed: @escaping @MainActor () -> Void
    ) -> SimulatorAudioInterface.RouteChanged {
        { _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { changed() } } }
    }

    private nonisolated static func routeCompleted(
        _ completion: @escaping @MainActor (Error?) -> Void
    ) -> SimulatorAudioInterface.RouteCompletion {
        { error in DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } } }
    }

    func state() throws -> AudioRouteState {
        var devices: [HostAudioDevice] = []
        for object in try unsafe availableDevices.unsafeInvoke() ?? [] {
            let members = try self.members ?? HostAudioDeviceMembers(object)
            self.members = members
            if let device = try members.device(object) { devices.append(device) }
        }
        return AudioRouteState(devices: devices,
                               inputRoute: try unsafe inputRoute.unsafeInvoke(),
                               outputRoute: try unsafe outputRoute.unsafeInvoke(),
                               defaultInput: try unsafe defaultInput.unsafeInvoke(),
                               defaultOutput: try unsafe defaultOutput.unsafeInvoke())
    }

    func route(_ scope: AudioScope, to route: String, completion: @escaping @MainActor (Error?) -> Void) throws {
        try unsafe routeGuest.unsafeInvoke(scope.rawValue, route, .main, Self.routeCompleted(completion))
    }

    func disconnect() {
        guard isConnected else { return }
        isConnected = false
        do { try unsafe unregister.unsafeInvoke(token) } catch {
            hostLog("Could not stop the audio route reports: \(error.localizedDescription)")
        }
    }
}

/// `SimAudioHostDevice`'s members. The Mac's devices are proxies of one
/// class, so the members are bound to the first and sent to each.
@MainActor
private struct HostAudioDeviceMembers {
    static let selectors = ["uniqueIdentifier", "displayName", "inputChannels", "outputChannels", "isDefaultInScopes"]

    let uniqueIdentifier: NativeObjCMethod<String?>
    let displayName: NativeObjCMethod<String?>
    let inputChannels: NativeObjCMethod<Int>
    let outputChannels: NativeObjCMethod<Int>
    let defaultScopes: NativeObjCMethod<UInt64>

    init(_ device: AnyObject) throws {
        let object = ABIRuntime.shared.object(device)
        uniqueIdentifier = try object.resolveMethodAndWait(selector: "uniqueIdentifier", as: (() -> String?).self).method
        displayName = try object.resolveMethodAndWait(selector: "displayName", as: (() -> String?).self).method
        inputChannels = try object.resolveMethodAndWait(selector: "inputChannels", as: (() -> Int).self).method
        outputChannels = try object.resolveMethodAndWait(selector: "outputChannels", as: (() -> Int).self).method
        defaultScopes = try object.resolveMethodAndWait(selector: "isDefaultInScopes", as: (() -> UInt64).self).method
    }

    /// The device, or nil for one without an identifier, which no route can name.
    func device(_ object: AnyObject) throws -> HostAudioDevice? {
        guard let uid = try unsafe uniqueIdentifier.unsafeInvoke(on: object) else { return nil }
        return HostAudioDevice(uid: uid, name: try unsafe displayName.unsafeInvoke(on: object) ?? uid,
                               inputChannels: try unsafe inputChannels.unsafeInvoke(on: object),
                               outputChannels: try unsafe outputChannels.unsafeInvoke(on: object),
                               defaultScopes: try unsafe defaultScopes.unsafeInvoke(on: object))
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

/// A watch gesture of Device ▸ Gestures, by the value
/// `IndigoHIDMessageForWatchGesture` takes, which is also Simulator.app's
/// menu tag.
enum WatchGesture: UInt32 {
    case doubleTap = 0, wristFlick = 1
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
    /// The view that takes the device's input in the window: the screen's
    /// digitizer, or the overlay of the display's user-interface plugin once
    /// `userInterfacePlugin()` found it.
    var inputView: NSView { get }
    /// The user-interface plugin SimulatorKit attached to the display, or nil
    /// for a device type without one and until the display loaded it. A
    /// thrown error means that the plugin cannot be used, for example
    /// because it loaded code from another Xcode.
    func userInterfacePlugin() throws -> SimulatorUserInterfacePlugin?
    /// The state of the screen's backlight as CoreSimulator reports it now,
    /// `SimScreenProperties.backlight.state`, or nil when it cannot be read.
    /// A watch's is 2 while its display is on, 1 while an always-on display
    /// is dimmed, and 0 while the display is off.
    var backlightState: Int32? { get }
    /// Posts Simulator.app's `SimulatorVideoRecordingStartedNotification` or
    /// `SimulatorVideoRecordingStoppedNotification` for the device, which a
    /// user-interface plugin observes to show the recording on its toolbar.
    func announceRecording(started: Bool)
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
    /// Sends a watch gesture. `completion` receives SimulatorKit's delivery
    /// result; a thrown error means the gesture was not sent.
    func send(_ gesture: WatchGesture, completion: @escaping @MainActor (Error?) -> Void) throws
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
    /// Connects to the device's audio route port. `changed` runs on the main
    /// actor after each change the port reports, until it disconnects.
    func connectAudioRoutes(changed: @escaping @MainActor () -> Void) throws -> any SimulatorAudioRoutes
    /// Connects to the device's external display, or returns nil for a
    /// device without one. `changed` runs on the main actor after each change
    /// of its properties, such as its power and size, until it disconnects.
    func connectExternalScreen(changed: @escaping @MainActor () -> Void) throws -> (any SimulatorExternalScreen)?
    func setChromeVisible(_ visible: Bool)
    func setActive(_ active: Bool)
    func setKeyboardEnabled(_ enabled: Bool)
    /// `SimDigitizerInputView.supportScrolling`: whether the digitizer passes
    /// the pointer's scrolling to the device, which turns its Digital Crown
    /// or Digital Dial.
    func setSupportsScrolling(_ supports: Bool)
    /// Tells the guest's UIKit whether edge swipes start on the bezel, as
    /// Simulator.app's `SimDevice wantsEdgeSwipes:` does: sets the guest's
    /// `com.apple.UIKit.SimulatorWantsEdgeSwipes` state to 1 or 0 and posts it.
    /// While it is 1, UIKit's `_UIScreenEdgePanRecognizer` takes only the
    /// touches that the digitizer marks as starting at an edge, which a drag
    /// from the bezel into the screen makes, and otherwise any touch that
    /// starts near an edge.
    func setWantsEdgeSwipes(_ wants: Bool)
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
    /// `SimDisplayView.digitizerView`.
    private let digitizerView: NSView
    /// The display's user-interface plugin, once found.
    private var plugin: SimulatorUserInterfacePlugin?
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
            digitizerView = try unsafe display.digitizerView.unsafeInvoke(on: view)
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

    var inputView: NSView { plugin?.overlayView ?? digitizerView }

    func userInterfacePlugin() throws -> SimulatorUserInterfacePlugin? {
        if let plugin { return plugin }
        let display = runtime.display
        guard !disconnected, let object = object_getIvar(view, display.userInterfacePlugin) as AnyObject? else {
            return nil
        }
        // The plugin's bundle and what it loaded are checked as the display's
        // own frameworks are.
        try runtime.validateLoadedImages()
        let plugin = SimulatorUserInterfacePlugin(
            overlayView: try display.pluginMessages.send("overlayView", to: object, as: NSView?.self),
            toolbar: try display.pluginMessages.send("toolbar", to: object, as: NSToolbar?.self))
        self.plugin = plugin
        return plugin
    }

    /// The messages that read the backlight, by protocol.
    static let backlightSelectors = [("SimScreenProperties", ["backlight"]), ("SimScreenBacklight", ["state"])]

    // SimDisplayView's `backlightState` follows the screen's properties only
    // after their change is reported, so the properties are read instead, as
    // Simulator.app reads them when they change.
    var backlightState: Int32? {
        guard !disconnected else { return nil }
        let display = runtime.display
        return read("read the backlight", otherwise: nil) {
            let properties = try unsafe display.screenProperties.unsafeInvoke(on: screen)
            return try display.screenMessages.send("backlight", to: properties, as: AnyObject?.self)
                .map { try display.screenMessages.send("state", to: $0, as: Int32.self) }
        }
    }

    func announceRecording(started: Bool) {
        let name = started ? "SimulatorVideoRecordingStartedNotification" : "SimulatorVideoRecordingStoppedNotification"
        NotificationCenter.default.post(name: Notification.Name(name), object: nil,
                                        userInfo: [name + "DeviceUserInfoKey": device.object])
    }

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

    func send(_ gesture: WatchGesture, completion: @escaping @MainActor (Error?) -> Void) throws {
        guard let hidClient else { throw HostError.operation("Simulator input is disconnected") }
        try runtime.input.send(gesture, client: hidClient, completion: completion)
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
    func connectAudioRoutes(changed: @escaping @MainActor () -> Void) throws -> any SimulatorAudioRoutes {
        try runtime.audio.connect(to: device, changed: changed)
    }
    func connectExternalScreen(changed: @escaping @MainActor () -> Void) throws -> (any SimulatorExternalScreen)? {
        try runtime.display.externalScreen(of: device).map {
            try SimulatorExternalScreenConnection(device: device, screen: $0, runtime: runtime, changed: changed)
        }
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
    func setSupportsScrolling(_ supports: Bool) {
        guard !disconnected else { return }
        perform("enable scrolling") {
            try unsafe runtime.display.setSupportsScrolling.unsafeInvoke(on: digitizerView, supports)
        }
    }
    func setWantsEdgeSwipes(_ wants: Bool) {
        guard !disconnected else { return }
        perform("tell the device whether edge swipes start on the bezel") {
            let name = "com.apple.UIKit.SimulatorWantsEdgeSwipes"
            try device.setNotificationState(name, to: wants ? 1 : 0)
            try device.postNotification(name)
        }
    }
    func setSupportsTouchPressure(_ supports: Bool) {
        guard !disconnected else { return }
        perform("enable touch pressure") {
            try unsafe runtime.display.setSupportsTouchPressure.unsafeInvoke(on: digitizerView, supports)
        }
    }
    func setUsesTrackpadForce(_ uses: Bool) {
        guard !disconnected else { return }
        perform("use the trackpad's force") {
            try unsafe runtime.display.setUsesTrackpadForce.unsafeInvoke(on: digitizerView, uses)
        }
    }
    func setSimulatedTouchMode(_ mode: SimulatedTouchMode) {
        guard !disconnected else { return }
        perform("set the touch pressure") {
            try unsafe runtime.display.setSimulatedTouchMode.unsafeInvoke(on: digitizerView, mode.rawValue)
        }
    }
    func setTouchIndicator(_ indicator: TouchIndicator, shown: Bool) {
        guard !disconnected else { return }
        let display = runtime.display
        perform("show touch indicators") {
            let options = try unsafe display.drawOptionRawValue.unsafeInvoke(on: display.drawOptions.unsafeInvoke(on: digitizerView))
            let option = display.drawOption(for: indicator)
            try unsafe display.setDrawOptions.unsafeInvoke(
                on: digitizerView, display.makeDrawOption.unsafeInvoke(shown ? options | option : options & ~option))
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
