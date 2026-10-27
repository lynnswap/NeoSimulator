import ABIBridge
import AppKit
@_spi(NeoSimulator) import XcodeSimulatorHost
import Darwin
import MachO
import ObjectiveC

// SimulatorKit passes rotations as Measurement<UnitAngle>, whose layout only
// its metadata establishes.
extension Measurement: @retroactive ABIBridgeSwiftValue where UnitType == UnitAngle {
    public static var swiftABIType: NativeType { try! .opaque(named: "Measurement") }
}

/// Uses one UI toolkit per process and a separate CoreSimulator context for each Xcode.
@MainActor
final class SimulatorRuntime {
    private static var loadedUIXcodeURL: URL?
    private static var contextXcodeURLs: Set<URL> = []
    private static var preparations: [URL: Task<SimulatorRuntime, any Error>] = [:]
    /// The Xcode that owns this device context and its command-line tools.
    let xcodeURL: URL
    /// The process's fixed SimulatorKit and user-interface factory.
    let uiXcodeURL: URL
    let coreSimulator: CoreSimulatorInterface
    let display: SimulatorDisplayInterface
    let input: SimulatorInputInterface
    let pasteboard: SimulatorPasteboardInterface
    let audio: SimulatorAudioInterface

    /// Joins a context's in-flight preparation while its native values stay on the main actor.
    static func load(xcodeURL: URL, uiXcodeURL: URL? = nil) async throws -> SimulatorRuntime {
        try Task.checkCancellation()
        let source = xcodeURL.resolvingSymlinksInPath()
        if let preparation = preparations[source] {
            let runtime = try await preparation.value
            if let requestedUI = uiXcodeURL?.resolvingSymlinksInPath(), runtime.uiXcodeURL != requestedUI {
                throw HostError.unavailable("SimulatorKit is already loaded from \(runtime.uiXcodeURL.path)")
            }
            try Task.checkCancellation()
            return runtime
        }
        let preparation = Task {
            let requestedUI = (uiXcodeURL ?? loadedUIXcodeURL ?? source).resolvingSymlinksInPath()
            return try await SimulatorRuntime(xcodeURL: source, uiXcodeURL: requestedUI)
        }
        preparations[source] = preparation
        defer { preparations[source] = nil }
        let runtime = try await preparation.value
        try Task.checkCancellation()
        return runtime
    }

    private init(xcodeURL: URL, uiXcodeURL: URL) async throws {
        self.xcodeURL = xcodeURL.resolvingSymlinksInPath()
        let requestedUI = uiXcodeURL.resolvingSymlinksInPath()
        if let loaded = Self.loadedUIXcodeURL, loaded != requestedUI {
            throw HostError.unavailable("SimulatorKit is already loaded from \(loaded.path)")
        }
        self.uiXcodeURL = requestedUI
        try Self.load(URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"))
        try Self.load(requestedUI.appendingPathComponent("Contents/SharedFrameworks/SimulatorKit.framework"))
        // Objective-C registration cannot be undone after a later binding failure.
        Self.loadedUIXcodeURL = requestedUI
        try Self.load(requestedUI.appendingPathComponent("Contents/Frameworks/IDEPlaygroundSimulator.framework"))
        Self.contextXcodeURLs.insert(self.xcodeURL)
        let runtime = ABIRuntime.shared
        coreSimulator = try await CoreSimulatorInterface(runtime: runtime)
        display = try await SimulatorDisplayInterface(runtime: runtime)
        input = try await SimulatorInputInterface(runtime: runtime)
        pasteboard = try await SimulatorPasteboardInterface(runtime: runtime)
        audio = try await SimulatorAudioInterface(runtime: runtime)
        try validateLoadedImages()
    }

    static func creationCatalog(xcodeURL: URL) async throws -> SimulatorCatalog {
        try load(URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"))
        let interface = try await CoreSimulatorInterface(runtime: .shared)
        let set = try SimulatorDeviceSet(interface: interface,
                                         developerDirectory: xcodeURL.appendingPathComponent("Contents/Developer").path)
        return try set.readCatalog()
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

    /// Keeps the UI toolkit fixed while allowing plugins belonging to an opened device context.
    func validateLoadedImages() throws {
        let prefix = uiXcodeURL.path + "/"
        for index in 0..<_dyld_image_count() {
            guard let pointer = _dyld_get_image_name(index) else { continue }
            let path = URL(fileURLWithPath: String(cString: pointer)).resolvingSymlinksInPath().path
            if path.contains("/DeviceHub.app/") {
                throw HostError.unavailable("Forbidden Device Hub component is loaded: \(path)")
            }
            if (path.contains("/SimulatorKit.framework/") || path.contains("/IDEPlaygroundSimulator.framework/")),
               !path.hasPrefix(prefix) {
                throw HostError.unavailable("Private simulator code came from a different Xcode: \(path)")
            }
            if path.contains(".simdeviceui/"), !path.hasPrefix(prefix),
               !Self.contextXcodeURLs.contains(where: { path.hasPrefix($0.path + "/") }) {
                throw HostError.unavailable("The simulator UI plugin does not belong to an opened Xcode context: \(path)")
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
    /// Screens currently published by the device's screen adapter.
    let adapterScreens: NativeSwiftMethod<() -> [UInt32: NativeSwiftValue]>
    typealias AdapterEventHandler = NativeSwiftClosure<(NativeSwiftValue) -> Void>
    /// Screen-adapter registration. Releasing the token ends callbacks except those already queued.
    let registerAdapterEvents: NativeSwiftMethod<(UInt32?, DispatchQueue, AdapterEventHandler) -> AnyObject>
    /// Messages to CoreSimDeviceIO's screen proxies: `SimScreenProperties`
    /// and `SimScreenMode`.
    let screenMessages = ProxyMessages()
    /// Default CarPlay properties: `SimCarPlayPropertyKeyStark` and `SimCarPlayPropertyKeyHasTouchScreen`.
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
    /// `SimDisplayView._userInterfacePlugin` has no getter and stores one object.
    /// SimulatorKit loads it while connecting a device with a user-interface profile.
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

    init(runtime: ABIRuntime) async throws {
        guard let screenClass = NSClassFromString("SimulatorKit.SimDeviceScreen"),
            let factoryClass = NSClassFromString("IDEPlaygroundSimulator.IDESimulatorPlaygroundUntil"),
            let displayViewClass = NSClassFromString("SimulatorKit.SimDisplayView")
        else {
            throw HostError.unavailable("SimulatorKit display classes are unavailable")
        }
        self.factoryClass = factoryClass
        screen = try await runtime.resolve(.objc(.method("screen", as: (() -> AnyObject?).self)), on: screenClass)
        isDefault = try await runtime.resolve(.objc(.method("isDefault", as: (() -> Bool).self)), on: screenClass)
        isCarPlay = try await runtime.resolve(.objc(.method("isCarPlay", as: (() -> Bool).self)), on: screenClass)
        let deviceScreen = try await runtime.resolve(.swift(.type("SimulatorKit.SimDeviceScreen")))
        // SimulatorKit does not export the descriptors of the imported C types
        // these getters return, so the host integers state their conventions.
        let uint32 = try await runtime.resolve(.swift(.type("Swift.UInt32")))
        let uint16 = try await runtime.resolve(.swift(.type("Swift.UInt16")))
        buttonTarget = try await deviceScreen.resolve(.swift(.getter(
            "buttonTarget.getter : __C.IndigoHIDTarget", as: (() -> UInt32).self,
            valueABIs: [uint32: .uint32])))
        // The event types and events are resilient, so they are passed indirectly.
        let eventTypes = try await runtime.resolve(.swift(.type("SimulatorKit.SimDeviceScreen.ScreenEventTypes")))
        let event = try await runtime.resolve(.swift(.type("SimulatorKit.SimDeviceScreen.ScreenEvent")))
        let eventABIs: [NativeSwiftType: NativeType] = [
            eventTypes: try .opaque(named: eventTypes.name), event: try .opaque(named: event.name),
        ]
        screenPropertyEvents = try await unsafe eventTypes
            .resolve(.swift(.staticGetter("properties", as: (() -> NativeSwiftValue).self, valueABIs: eventABIs)))
            .unsafeInvoke()
        screenProperties = try await deviceScreen.resolve(.swift(.getter(
            "properties.getter : __C.SimScreenProperties", as: (() -> AnyObject).self)))
        screenScale = try await deviceScreen.resolve(.swift(.getter(
            "scale.getter : CoreGraphics.CGFloat", as: (() -> CGFloat).self)))
        // CoreSimulator declares `SimDisplayClass` as an unsigned short.
        displayClass = try await deviceScreen.resolve(.swift(.getter(
            "displayClass.getter : __C.SimDisplayClass", as: (() -> UInt16).self,
            valueABIs: [uint16: .uint16])))
        registerScreenEvents = try await deviceScreen.resolve(.swift(.method(
            "register(types:queue:handler:)",
            as: ((NativeSwiftValue, DispatchQueue, ScreenEventHandler) -> NativeSwiftValue).self,
            valueABIs: eventABIs)))
        let adapterType = try await runtime.resolve(.swift(.type("SimulatorKit.SimDeviceScreenAdapter")))
        adapterScreens = try await adapterType.resolve(.swift(.getter("screens", as: (() -> [UInt32: NativeSwiftValue]).self)))
        registerAdapterEvents = try await adapterType.resolve(.swift(.method("register(screenID:queue:handler:)",
            as: ((UInt32?, DispatchQueue, AdapterEventHandler) -> AnyObject).self)))
        // Screen proxies are bound on connection; their protocols must declare these messages.
        for (name, selectors) in SimulatorExternalScreenConnection.selectors + SimulatorConnection.backlightSelectors {
            guard let declared = objc_getProtocol(name) else {
                throw HostError.unavailable("Required private protocol \(name) is unavailable")
            }
            for selector in selectors
            where unsafe protocol_getMethodDescription(declared, NSSelectorFromString(selector), true, true).name == nil {
                throw HostError.unavailable("\(name) does not declare \(selector)")
            }
        }
        func carPlayKey(_ name: String) async throws -> String {
            let symbol = try await runtime.resolve(.c(.symbol(name, kind: .data)))
            guard let key = unsafe symbol.withUnsafeAddress({
                unsafe $0.load(as: Unmanaged<NSString>?.self)?.takeUnretainedValue() as String?
            }) else {
                throw HostError.unavailable("\(name) has no value")
            }
            return key
        }
        carPlayProperties = [try await carPlayKey("SimCarPlayPropertyKeyStark"): true,
                             try await carPlayKey("SimCarPlayPropertyKeyHasTouchScreen"): true]
        createDisplay = try await runtime.resolve(
            .objc(.method("createSimDisplayViewWithDevice:simScreenID:", as: ((AnyObject, UInt32) -> NSView?).self)),
            on: factoryClass, classMethod: true)

        // SimDisplayView members are exported only through dispatch thunks.
        let view = try await runtime.resolve(.swift(.type("SimulatorKit.SimDisplayView")))
        showChrome = try await view.resolve(.swift(.setter("showDeviceChrome", as: ((Bool) -> Void).self)))
        chromeView = try await view.resolve(.swift(.getter(
            "chromeView.getter : SimulatorKit.SimDisplayChromeView", as: (() -> NSView).self)))
        digitizerView = try await view.resolve(.swift(.getter(
            "digitizerView.getter : SimulatorKit.SimDigitizerInputView", as: (() -> NSView).self)))
        renderScale = try await view.resolve(.swift(.getter("renderScale", as: (() -> CGFloat).self)))
        setRenderScale = try await view.resolve(.swift(.setter("renderScale", as: ((CGFloat) -> Void).self)))
        sizeForScale = try await view.resolve(.swift(.method("size(for:)", as: ((CGFloat) -> CGSize).self)))
        scaleForSize = try await view.resolve(.swift(.method("scale(for:)", as: ((CGSize) -> CGFloat).self)))
        rotation = try await view.resolve(.swift(.setter("deviceRotation", as: ((Measurement<UnitAngle>) -> Void).self)))
        disconnect = try await view.resolve(.swift(.method(
            "disconnect(completion: (() -> ())?) -> ()",
            as: ((NativeSwiftClosure<() -> Void>) -> Void).self)))
        beginResize = try await view.resolve(.swift(.method("beginResize()", as: (() -> Void).self)))
        resize = try await view.resolve(.swift(.method("resizeTo(size:)", as: ((CGSize) -> Void).self)))
        endResize = try await view.resolve(.swift(.method("endResize()", as: (() -> Void).self)))
        // The resize corners and their types are resilient, so they are passed
        // indirectly, and the array's own members read its elements.
        let typedResizeRect = try await runtime.resolve(.swift(.type("SimulatorKit.SimDisplayView.TypedResizeRect")))
        let typedResizeRects = try await runtime.resolve(.swift(.type("Swift.Array", genericArguments: [.type(typedResizeRect)])))
        let resizeRectType = try await runtime.resolve(.swift(.type("SimulatorKit.SimDeviceChrome.ResizeRectType")))
        resizeRects = try await view.resolve(.swift(.getter(
            "typedResizeRects.getter : [SimulatorKit.SimDisplayView.TypedResizeRect]",
            as: (() -> NativeSwiftValue).self)))
        resizeRectCount = try await typedResizeRects.resolve(.swift(.getter("count", as: (() -> Int).self)))
        resizeRectAtIndex = try await typedResizeRects.resolve(.swift(.getter(
            "Swift.Array.subscript.getter : (Swift.Int) -> A", as: ((Int) -> NativeSwiftValue).self)))
        resizeRectFrame = try await typedResizeRect.resolve(.swift(.getter(
            "rect.getter : __C.CGRect", as: (() -> CGRect).self, receiverABI: .opaque(named: typedResizeRect.name))))
        self.resizeRectType = try await typedResizeRect.resolve(.swift(.getter(
            "type.getter : SimulatorKit.SimDeviceChrome.ResizeRectType", as: (() -> NativeSwiftValue).self,
            valueABIs: [resizeRectType: try .opaque(named: resizeRectType.name)],
            receiverABI: .opaque(named: typedResizeRect.name))))
        resizeRectTypeName = try await resizeRectType.resolve(.swift(.getter(
            "rawValue.getter : Swift.String", as: (() -> String).self,
            receiverABI: .opaque(named: resizeRectType.name))))
        showResizeCursors = try await view.resolve(.swift(.setter("showResizeCursors", as: ((Bool) -> Void).self)))

        chromeState = try await runtime.resolve(.swift(.type("SimulatorKit.SimDisplayChromeView.State")))
        let chromeViewType = try await runtime.resolve(.swift(.type("SimulatorKit.SimDisplayChromeView")))
        setChromeState = try await chromeViewType.resolve(.swift(.setter(
            "state.setter : SimulatorKit.SimDisplayChromeView.State",
            as: ((NativeSwiftValue) -> Void).self,
            valueABIs: [chromeState: try .opaque(named: chromeState.name)])))
        // The chrome and its images are resilient, so they are passed indirectly.
        let deviceChrome = try await runtime.resolve(.swift(.type("SimulatorKit.SimDeviceChrome")))
        let optionalChrome = try await runtime.resolve(.swift(.type("Swift.Optional",
                                                                 genericArguments: [.type(deviceChrome)])))
        let images = try await runtime.resolve(.swift(.type("SimulatorKit.SimDeviceChrome.Images")))
        chrome = try await chromeViewType.resolve(.swift(.getter(
            "chrome.getter : SimulatorKit.SimDeviceChrome?", as: (() -> NativeSwiftValue).self,
            valueABIs: [optionalChrome: try .opaque(named: optionalChrome.name)])))
        chromeImages = try await deviceChrome.resolve(.swift(.getter(
            "images.getter : SimulatorKit.SimDeviceChrome.Images", as: (() -> NativeSwiftValue).self,
            valueABIs: [images: try .opaque(named: images.name)], receiverABI: .opaque(named: deviceChrome.name))))
        chromeImagesPadding = try await images.resolve(.swift(.getter(
            "padding.getter : __C.CGSize", as: (() -> CGSize).self, receiverABI: .opaque(named: images.name))))
        setKeyboardEnabled = try await runtime.resolve(.swift(.type("SimulatorKit.SimKeyboardInputDefaultDelegate")))
            .resolve(.swift(.setter("isEnabled", as: ((Bool) -> Void).self)))
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
        let digitizer = try await runtime.resolve(.swift(.type("SimulatorKit.SimDigitizerInputView")))
        setSupportsScrolling = try await digitizer.resolve(.swift(.setter("supportScrolling", as: ((Bool) -> Void).self)))
        setSupportsTouchPressure = try await digitizer.resolve(
            .swift(.setter("supportTouchPressure", as: ((Bool) -> Void).self)))
        setUsesTrackpadForce = try await digitizer.resolve(
            .swift(.setter("useForceTrackpadForPressure", as: ((Bool) -> Void).self)))
        // TouchMode has no field metadata to establish its convention.
        let touchMode = try await runtime.resolve(.swift(.type("SimulatorKit.SimDigitizerInputView.TouchMode")))
        setSimulatedTouchMode = try await digitizer.resolve(.swift(.setter(
            "simulatedTouchMode.setter : SimulatorKit.SimDigitizerInputView.TouchMode", as: ((Int) -> Void).self,
            valueABIs: [touchMode: .int])))
        let drawOption = try await runtime.resolve(.swift(.type("SimulatorKit.SimDigitizerInputView.DrawOption")))
        let drawOptionABIs: [NativeSwiftType: NativeType] = [drawOption: try .opaque(named: drawOption.name)]
        drawOptions = try await digitizer.resolve(.swift(.getter(
            "drawOptions.getter : SimulatorKit.SimDigitizerInputView.DrawOption",
            as: (() -> NativeSwiftValue).self, valueABIs: drawOptionABIs)))
        setDrawOptions = try await digitizer.resolve(.swift(.setter(
            "drawOptions.setter : SimulatorKit.SimDigitizerInputView.DrawOption",
            as: ((NativeSwiftValue) -> Void).self, valueABIs: drawOptionABIs)))
        let rawValue = try await drawOption.resolve(.swift(.getter(
            "rawValue.getter : Swift.Int", as: (() -> Int).self, receiverABI: .opaque(named: drawOption.name))))
        drawOptionRawValue = rawValue
        makeDrawOption = try await drawOption.resolve(.swift(.initializer(
            "init(rawValue:)", as: ((Int) -> NativeSwiftValue).self, valueABIs: drawOptionABIs)))
        func option(_ name: String) async throws -> Int {
            try await unsafe rawValue.unsafeInvoke(on: drawOption.resolve(.swift(.staticGetter(
                name, as: (() -> NativeSwiftValue).self, valueABIs: drawOptionABIs))).unsafeInvoke())
        }
        touchIndicatorOptions = (try await option("normalTouch"), try await option("pinchTouches"), try await option("pinchPivotPoint"),
                                 try await option("edgeGestures"))
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
        // The synchronous screen initializer waits for missing IDs and blocks AppKit during boot.
        guard let adapter = try? screenAdapter.adapter(of: device.object),
              let screens = try? unsafe adapterScreens.unsafeInvoke(on: adapter) else { return nil }
        for (identifier, value) in screens.sorted(by: { $0.key < $1.key }) {
            guard let screen = try? value.withCopy({ $0 as AnyObject }),
                let _ = try? unsafe self.screen.unsafeInvoke(on: screen),
                (try? unsafe isDefault.unsafeInvoke(on: screen)) == true,
                (try? unsafe isCarPlay.unsafeInvoke(on: screen)) == false
            else { continue }
            return (identifier, screen)
        }
        return nil
    }

    func appScreen(uniqueID: String, of device: SimulatorDevice) throws -> (identifier: UInt32, object: AnyObject)? {
        guard let adapter = try screenAdapter.adapter(of: device.object) else { return nil }
        for (identifier, value) in try unsafe adapterScreens.unsafeInvoke(on: adapter) {
            let screen = try value.withCopy { $0 as AnyObject }
            let properties = try unsafe screenProperties.unsafeInvoke(on: screen)
            if try screenMessages.send("uniqueId", to: properties, as: String?.self) == uniqueID {
                return (identifier, screen)
            }
        }
        return nil
    }

    /// `SimScreenType`'s TVOut, the external display that I/O ▸ External
    /// Displays configures. 0 is a device's own screen and 2 is CarPlay.
    static let externalScreenType: UInt64 = 1

    /// Observes connected TVOut screens on the main queue, including future connections.
    /// Releasing the token ends reports except those already queued; nil means no adapter.
    func registerForExternalScreens(
        of device: SimulatorDevice,
        found: @escaping @MainActor (Result<(identifier: UInt32, object: AnyObject), any Error>) -> Void
    ) throws -> AnyObject? {
        guard let adapter = try screenAdapter.adapter(of: device.object) else { return nil }
        let handler = try AdapterEventHandler { event in
            // The adapter reports on the main queue, which the event never leaves.
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated {
                do {
                    // A disconnection also carries its screen.
                    guard let screen = try event.copyEnumPayloadAndWait(forCase: "connected")?
                        .withCopy({ $0 as AnyObject }) else { return }
                    let properties = try unsafe screenProperties.unsafeInvoke(on: screen)
                    guard try screenMessages.send("screenType", to: properties, as: UInt64.self) == Self.externalScreenType
                    else { return }
                    found(.success((try screenMessages.send("screenID", to: properties, as: UInt32.self), screen)))
                } catch {
                    found(.failure(error))
                }
            }
        }
        return try unsafe registerAdapterEvents.unsafeInvoke(on: adapter, UInt32?.none, .main, handler)
    }
}

/// ABIBridge must bind the SimDevice extension member through an instance.
/// Reuse the first binding for subsequent devices.
@MainActor
final class ScreenAdapterGetter {
    private var getter: NativeSwiftMethod<() -> AnyObject?>?

    /// The device's `SimDeviceScreenAdapter`, which SimulatorKit keeps for
    /// the device's lifetime, or nil when it has none.
    func adapter(of device: AnyObject) throws -> AnyObject? {
        let getter = try self.getter ?? ABIRuntime.shared.object(device).resolveAndWait(.swift(.getter(
            "(extension in SimulatorKit):__C.SimDevice.screenAdapter.getter : SimulatorKit.SimDeviceScreenAdapter?",
            as: (() -> AnyObject?).self))).method
        self.getter = getter
        return try unsafe getter.unsafeInvoke(on: device)
    }
}

/// Caches no-argument Objective-C messages by proxy or plugin class.
@MainActor
final class ProxyMessages {
    private var methods: [String: Any] = [:]

    func send<Result>(_ selector: String, to object: AnyObject, as type: Result.Type = Result.self) throws -> Result {
        let key = "\(ObjectIdentifier(Swift.type(of: object))) \(selector)"
        let method = try methods[key] as? NativeObjCMethod<Result> ?? ABIRuntime.shared.object(object)
            .resolveAndWait(.objc(.method(selector, as: (() -> Result).self))).method
        methods[key] = method
        return try unsafe method.unsafeInvoke(on: object)
    }
}

/// The selected Xcode's device-profile plugin. SimulatorKit owns its input overlay;
/// the host installs its toolbar and forwards commands through the responder chain.
struct SimulatorUserInterfacePlugin {
    /// The messages the host sends to a plugin.
    static let selectors = ["overlayView", "toolbar"]

    let overlayView: NSView?
    let toolbar: NSToolbar?
}

/// Connection to the device's existing TVOut screen, also used for CarPlay.
/// CoreSimulator exposes no creatable screen properties for devices without one.
@MainActor
protocol SimulatorExternalScreen: AnyObject {
    var screenID: UInt32 { get }
    /// When the device last booted. The guest's CarPlay session belongs to
    /// the boot that started it.
    var deviceBootDate: Date? { get }
    /// The screen's power, size, scale, CarPlay, and refresh rate as
    /// CoreSimulator reports them now.
    func state() throws -> ExternalScreenState
    /// The modes the screen advertises, `supportedScreenModes`, which stay the
    /// same while the device runs; only their order changes between reads.
    func supportedModes() throws -> [ExternalScreenMode]
    /// Sets a supported screen mode and powers it on, optionally with CarPlay properties.
    /// A throw means nothing was sent; completion reports the result on the main actor.
    func setMode(pixelSize: CGSize, scale: CGFloat, carPlay: Bool,
                 completion: @escaping @MainActor (Error?) -> Void) throws
    /// `SimScreen setPowerState:0 …`. `completion` receives CoreSimulator's
    /// result on the main actor; a thrown error means nothing was sent.
    func powerOff(completion: @escaping @MainActor (Error?) -> Void) throws
    /// Writes the guest configuration read on mode changes: default CarPlay values or `{stark: 0}`.
    func saveCarPlayConfiguration(carPlay: Bool) throws
    /// Sends a counted CarPlay start/end for `boot`. Completion runs on the main actor.
    /// If the device restarted, no request is sent and completion receives `CarPlayRequestMoot`.
    func setCarPlayEnabled(_ enabled: Bool, inBoot boot: Date?, completion: @escaping @MainActor (Error?) -> Void)
    /// Creates or removes the guest's CarPlay HID service.
    /// A throw means nothing was sent; completion reports send status on the main actor.
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
        ("SimScreenProperties", ["screenID", "powerState", "screenType", "pixelSize", "currentMode",
                                 "supportedScreenModes", "carPlayProperties"]),
        ("SimScreenMode", ["sizeRule", "exactSize", "minSize", "maxSize", "allowedSizes", "preferredUIScale",
                           "refreshRate"]),
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
        setCurrentMode = try proxy.resolveAndWait(.objc(.method(
            "setCurrentMode:pixelSize:carPlayProperties:completionQueue:completionHandler:",
            as: ((AnyObject, CGSize, NSDictionary?, DispatchQueue, @escaping Completion) -> Void).self))).method
        setPowerState = try proxy.resolveAndWait(.objc(.method(
            "setPowerState:completionQueue:completionHandler:",
            as: ((Int32, DispatchQueue, @escaping Completion) -> Void).self))).method
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
            isCarPlay: try messages.send("carPlayProperties", to: properties, as: NSDictionary?.self) != nil,
            refreshRate: try currentMode.map { try refreshRate(of: $0) } ?? 0)
    }

    func supportedModes() throws -> [ExternalScreenMode] { try advertisedModes().map(mode) }

    func setMode(pixelSize size: CGSize, scale: CGFloat, carPlay: Bool,
                 completion: @escaping @MainActor (Error?) -> Void) throws {
        let simScreen = try connectedScreen()
        // One read of the modes, whose order the choice's index refers to.
        let advertised = try advertisedModes()
        let target: AnyObject? = switch try ExternalScreenMode.choice(
            for: size, scale: scale, current: try state(), among: try advertised.map(mode)) {
        case .current: try runtime.display.screenMessages.send("currentMode", to: try properties(), as: AnyObject?.self)
        case .advertised(let index): advertised[index]
        }
        guard let target else { throw HostError.operation("The external display has no current mode.") }
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
                                  scale: CGFloat(try messages.send("preferredUIScale", to: object, as: Double.self)),
                                  refreshRate: try refreshRate(of: object))
    }

    /// A `SimScreenMode`'s `refreshRate`, which CoreSimulator gives in
    /// hundredths of a hertz, in hertz.
    private func refreshRate(of mode: AnyObject) throws -> Double {
        Double(try runtime.display.screenMessages.send("refreshRate", to: mode, as: UInt32.self)) / 100
    }

    private func advertisedModes() throws -> [AnyObject] {
        try runtime.display.screenMessages.send("supportedScreenModes", to: try properties(), as: [AnyObject]?.self) ?? []
    }

    // CoreSimDeviceIO may ignore the completion queue. Bridge back to the main actor explicitly.
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
    /// CarPlay HID service messages target the external display's touch destination.
    let createCarPlayService: NativeFunction<OpaquePointer?, Bool>
    let removeCarPlayService: NativeFunction<OpaquePointer?>
    /// `IndigoHIDMessageForTrackpadMoveEvent`: normalized Apple TV Remote touch coordinates.
    let messageForTrackpadMove: NativeFunction<OpaquePointer?, CGPoint, UInt32>

    /// The targets that Simulator.app's Apple TV Remote sends its buttons and
    /// its touch surface's touches to, whatever the screen.
    static let tvRemoteButtonTarget: UInt32 = 0x15
    static let tvRemoteTouchTarget: UInt32 = 0x16

    init(runtime: ABIRuntime) async throws {
        guard let clientClass = NSClassFromString("SimulatorKit.SimDeviceLegacyHIDClient") else {
            throw HostError.unavailable("Required private class SimulatorKit.SimDeviceLegacyHIDClient is unavailable")
        }
        self.clientClass = clientClass
        makeClient = try await runtime.resolve(
            .objc(.method("initWithDevice:error:", as: ((AnyObject) throws -> AnyObject).self)),
            on: clientClass)
        send = try await runtime.resolve(
            .objc(.method("sendWithMessage:freeWhenDone:completionQueue:completion:",
                as: ((OpaquePointer, Bool, DispatchQueue?, Completion?) -> Void).self)),
            on: clientClass)
        messageForButton = try await runtime.resolve(.c(.function("IndigoHIDMessageForButton", as: ((UInt32, UInt32, UInt32) -> OpaquePointer?).self)))
        messageForUsage = try await runtime.resolve(.c(.function("IndigoHIDMessageForHIDArbitrary",
            as: ((UInt32, UInt32, UInt32, UInt32) -> OpaquePointer?).self)))
        messageForWatchGesture = try await runtime.resolve(.c(.function("IndigoHIDMessageForWatchGesture", as: ((UInt32) -> OpaquePointer?).self)))
        keyboardType = try await runtime.resolve(.c(.function("IndigoHIDGetKeyboardType", as: (() -> UInt32).self)))
        createCarPlayService = try await runtime.resolve(.c(.function("IndigoHIDMessageToCreateCarPlayService", as: ((Bool) -> OpaquePointer?).self)))
        removeCarPlayService = try await runtime.resolve(.c(.function("IndigoHIDMessageToRemoveCarPlayService", as: (() -> OpaquePointer?).self)))
        messageForTrackpadMove = try await runtime.resolve(.c(.function("IndigoHIDMessageForTrackpadMoveEvent", as: ((CGPoint, UInt32) -> OpaquePointer?).self)))
        try checkTrackpadMessage()
    }

    /// Validates fields patched for remote touch start/end before writing into the message.
    /// The layout matches Xcode 26.6 and 27.0–27.2; other layouts fail at runtime startup.
    private func checkTrackpadMessage() throws {
        guard let message = try unsafe messageForTrackpadMove.unsafeInvoke(CGPoint(x: 0.5, y: 0.5),
                                                                          Self.tvRemoteTouchTarget)
        else { throw HostError.operation("Could not allocate simulator input") }
        let raw = UnsafeMutableRawPointer(message)
        defer { free(raw) }
        let field = TrackpadMessage.self
        guard malloc_size(raw) >= field.size,
              raw.load(fromByteOffset: field.eventSizeOffset, as: UInt32.self) == field.eventSize,
              raw.load(fromByteOffset: field.eventCountOffset, as: UInt8.self) == field.eventCount,
              field.eventMasks.allSatisfy({ raw.load(fromByteOffset: $0, as: UInt32.self) == field.positionMask }),
              field.touchFlags.allSatisfy({ raw.load(fromByteOffset: $0, as: UInt32.self) == 1 })
        else {
            throw HostError.unavailable(
                "IndigoHIDMessageForTrackpadMoveEvent builds a message the Apple TV Remote's touch surface does not know")
        }
    }

    /// Returns the host keyboard type as the byte required by SimDevice, throwing on overflow.
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

    /// Device buttons use states 1/2; Apple TV Remote buttons use their own target and states 1/0.
    func message(_ input: HIDInput, _ state: HIDState, target: UInt32) throws -> HIDMessage {
        let message = switch input {
        case .button(let button): try unsafe messageForButton.unsafeInvoke(button.rawValue, state.rawValue, target)
        case .usage(let page, let usage): try unsafe messageForUsage.unsafeInvoke(target, page, usage, state.rawValue)
        case .tvRemote(let button):
            try unsafe messageForButton.unsafeInvoke(button.rawValue, state == .down ? 1 : 0, Self.tvRemoteButtonTarget)
        case .tvRemoteTouch: preconditionFailure("A touch's messages come from message(for:), which takes its point")
        }
        guard let message else { throw HostError.operation("Could not allocate simulator input") }
        return HIDMessage(input: input, state: state, pointer: message)
    }

    /// Sends a message. SimulatorKit reports delivery to `completion` on the
    /// main queue.
    func send(_ hidMessage: HIDMessage, client: AnyObject, completion: (@MainActor (Error?) -> Void)?) throws {
        try send(hidMessage.take(), client: client, completion: completion)
    }

    /// Builds and patches a remote touch message using the layout validated at startup.
    /// The caller must send or free the message.
    func message(for touch: TVRemoteTouch) throws -> OpaquePointer {
        guard let message = try unsafe messageForTrackpadMove.unsafeInvoke(touch.point, Self.tvRemoteTouchTarget) else {
            throw HostError.operation("Could not allocate simulator input")
        }
        let raw = UnsafeMutableRawPointer(message)
        for (offset, value) in TrackpadMessage.changes(for: touch.phase) {
            raw.storeBytes(of: value, toByteOffset: offset, as: UInt32.self)
        }
        return message
    }

    /// Sends a watch gesture, a single message without down and up events.
    func send(_ gesture: WatchGesture, client: AnyObject, completion: @escaping @MainActor (Error?) -> Void) throws {
        guard let message = try unsafe messageForWatchGesture.unsafeInvoke(gesture.rawValue) else {
            throw HostError.operation("Could not allocate simulator input")
        }
        try send(message, client: client, completion: completion)
    }

    /// Sends the CarPlay HID-service change; completion reports send status, not guest creation.
    /// The guest creates the service only once.
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
            // Keep the block literal: Optional.map conversion triggers a Swift 6.3 linker
            // reabstraction-thunk collision that can crash every block with this signature.
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

    init(runtime: ABIRuntime) async throws {
        guard let interfaceClass = NSClassFromString("SimPasteboardPlus.SimPasteboardInterface"),
              let listenerClass = NSClassFromString("SimPasteboardPlus.SimPasteboardInterfaceListener") else {
            throw HostError.unavailable("SimPasteboardPlus pasteboard classes are unavailable")
        }
        self.interfaceClass = interfaceClass
        makeInterface = try await runtime.resolve(
            .objc(.method("initWithConnectingToPort:managingPasteboard:delegate:delegateQueue:",
                as: ((UInt32, NSPasteboard, AnyObject?, DispatchQueue?) -> AnyObject).self)),
            on: interfaceClass)
        push = try await runtime.resolve(.objc(.method("push", as: (() -> Void).self)), on: interfaceClass)
        pull = try await runtime.resolve(.objc(.method("pull", as: (() -> Void).self)), on: interfaceClass)
        enableAutomaticSync = try await runtime.resolve(
            .objc(.method("enableRemoteAutosync", as: (() -> Void).self)),
            on: interfaceClass)
        disableAutomaticSync = try await runtime.resolve(
            .objc(.method("disableRemoteAutosync", as: (() -> Void).self)),
            on: interfaceClass)
        serviceName = try await unsafe runtime.resolve(
            .objc(.method("machServiceName", as: (() -> String).self)),
            on: listenerClass, classMethod: true)
            .unsafeInvoke(on: listenerClass as AnyObject)
    }

    /// Connects without transferring. Synchronization requires `enableRemoteAutosync`.
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
    /// The managed pasteboard was replaced; `generation` is its resulting change count.
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
    /// Enables bidirectional automatic synchronization without an immediate transfer.
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

/// Optional SimPasteboardDelegate callbacks arrive on the main queue.
/// The connection does not require declared protocol conformance.
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

/// Binds CoreSimDeviceIO's SimAudioHostRoutable port directly.
/// Xcode 27 removed SimulatorKit's SimDeviceAudioClient; this also supports custom device sets.
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

    init(runtime: ABIRuntime) async throws {
        guard let device = NSClassFromString("SimDevice"), let client = NSClassFromString("SimDeviceIOClient") else {
            throw HostError.unavailable("CoreSimulator's device I/O classes are unavailable")
        }
        deviceIO = try await runtime.resolve(.objc(.method("io", as: (() -> AnyObject?).self)), on: device)
        ioPorts = try await runtime.resolve(.objc(.method("ioPorts", as: (() -> [AnyObject]).self)), on: client)
        // Port and device objects are remote proxies, bound on connection through their protocols.
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
        let symbol = try await runtime.resolve(.c(.symbol("SimAudioHostUseSystemDefaultDeviceUID", kind: .data)))
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
                 changed: @escaping @MainActor (AudioRouteChange) -> Void) throws -> SimulatorAudioConnection {
        guard let io = try unsafe deviceIO.unsafeInvoke(on: device.object) else {
            throw HostError.unavailable("The device did not provide its I/O ports.")
        }
        var descriptor: NativeObjCMethod<AnyObject?>?
        for port in try unsafe ioPorts.unsafeInvoke(on: io) {
            // Every port is a proxy of one class.
            let method = try descriptor ?? ABIRuntime.shared.object(port)
                .resolveAndWait(.objc(.method("descriptor", as: (() -> AnyObject?).self))).method
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
    /// Routes to a device UID or system default. A throw means nothing was sent;
    /// completion reports on the main actor. CoreSimulator silently uses the default
    /// if the requested device is absent or lacks channels in this scope.
    func route(_ scope: AudioScope, to route: String, completion: @escaping @MainActor (Error?) -> Void) throws
    /// Stops the change reports.
    func disconnect()
}

/// Observes host-device and guest-route changes, including those made by other processes.
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

    fileprivate init(port: AnyObject, changed: @escaping @MainActor (AudioRouteChange) -> Void) throws {
        let object = ABIRuntime.shared.object(port)
        availableDevices = try object.resolveAndWait(.objc(.method(
            "availableHostDevices", as: (() -> [AnyObject]?).self)))
        inputRoute = try object.resolveAndWait(.objc(.method("guestInputHostDeviceUID", as: (() -> String?).self)))
        outputRoute = try object.resolveAndWait(.objc(.method("guestOutputHostDeviceUID", as: (() -> String?).self)))
        defaultInput = try object.resolveAndWait(.objc(.method(
            "effectiveDefaultInputDeviceUID", as: (() -> String?).self)))
        defaultOutput = try object.resolveAndWait(.objc(.method(
            "effectiveDefaultOutputDeviceUID", as: (() -> String?).self)))
        routeGuest = try object.resolveAndWait(.objc(.method(
            "routeGuestDeviceScope:toHostDeviceUID:completionQueue:completionHandler:",
            as: ((UInt64, String, DispatchQueue, @escaping SimulatorAudioInterface.RouteCompletion) -> Void).self)))
        unregister = try object.resolveAndWait(.objc(.method("unregisterCallbackWithUUID:", as: ((NSUUID) -> Void).self)))
        let registerDevices = try object.resolveAndWait(.objc(.method(
            "registerCallbackWithUUID:availableDevicesChangedCallback:",
            as: ((NSUUID, @escaping SimulatorAudioInterface.DevicesChanged) -> Void).self)))
        let registerRoutes = try object.resolveAndWait(.objc(.method(
            "registerCallbackWithUUID:selectedDeviceUIDChangedCallback:",
            as: ((NSUUID, @escaping SimulatorAudioInterface.RouteChanged) -> Void).self)))
        try unsafe registerDevices.unsafeInvoke(token, Self.devicesChanged(changed))
        do {
            try unsafe registerRoutes.unsafeInvoke(token, Self.routeChanged(changed))
        } catch {
            disconnect()
            throw error
        }
    }

    isolated deinit { disconnect() }

    // Audio-port callbacks may ignore the completion queue. Bridge to the main actor explicitly.
    private nonisolated static func devicesChanged(
        _ changed: @escaping @MainActor (AudioRouteChange) -> Void
    ) -> SimulatorAudioInterface.DevicesChanged {
        { _ in DispatchQueue.main.async { MainActor.assumeIsolated { changed(.availableDevices) } } }
    }

    private nonisolated static func routeChanged(
        _ changed: @escaping @MainActor (AudioRouteChange) -> Void
    ) -> SimulatorAudioInterface.RouteChanged {
        { _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { changed(.selectedDevice) } } }
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
        uniqueIdentifier = try object.resolveAndWait(.objc(.method("uniqueIdentifier", as: (() -> String?).self))).method
        displayName = try object.resolveAndWait(.objc(.method("displayName", as: (() -> String?).self))).method
        inputChannels = try object.resolveAndWait(.objc(.method("inputChannels", as: (() -> Int).self))).method
        outputChannels = try object.resolveAndWait(.objc(.method("outputChannels", as: (() -> Int).self))).method
        defaultScopes = try object.resolveAndWait(.objc(.method("isDefaultInScopes", as: (() -> UInt64).self))).method
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

/// A button of the Apple TV Remote, by the Indigo HID button number that
/// Simulator.app's remote sends.
enum TVRemoteButton: UInt32 {
    case select = 0x190, menu = 0x191, tv = 0x192, playPause = 0x194
    case volumeUp = 0x195, volumeDown = 0x196, siri = 0x3f2
}

/// A touch on the Apple TV Remote's touch surface.
struct TVRemoteTouch: Equatable {
    enum Phase { case began, moved, ended }

    var phase: Phase
    /// Where the touch is, from 0 to 1 from the surface's top-left corner.
    var point: CGPoint
}

/// Trackpad-message layout: header followed by two 0xA0-byte digitizer events.
/// The builder emits move events with position mask 4 and touch flags set;
/// remote touch start/end patch these fields.
private enum TrackpadMessage {
    /// The message's size, which its changes stay within.
    static let size = 0x160
    static let eventSizeOffset = 0x18, eventSize: UInt32 = 0xa0
    static let eventCountOffset = 0x1c, eventCount: UInt8 = 2
    /// The event masks of the first and second event.
    static let eventMasks = [0x38, 0xd8]
    static let positionMask: UInt32 = 4
    /// The touch flags of the first and second event.
    static let touchFlags = [0x64, 0x68, 0x104, 0x108]

    /// Start uses masks 0x23/3; end uses 0x21/1 and clears touch flags.
    /// Move preserves the builder's fields.
    static func changes(for phase: TVRemoteTouch.Phase) -> [(offset: Int, value: UInt32)] {
        switch phase {
        case .began: [(eventMasks[0], 0x23), (eventMasks[1], 3)]
        case .moved: []
        case .ended: [(eventMasks[0], 0x21), (eventMasks[1], 1)] + touchFlags.map { ($0, 0) }
        }
    }
}

/// Watch-gesture values accepted by IndigoHIDMessageForWatchGesture.
enum WatchGesture: UInt32 {
    case doubleTap = 0, wristFlick = 1
}

/// An input Simulator.app sends as a down event and an up event.
enum HIDInput: Hashable {
    case button(DeviceButton)
    /// A HID usage, such as a key on the consumer usage page.
    case usage(page: UInt32, usage: UInt32)
    /// A button of the Apple TV Remote.
    case tvRemote(TVRemoteButton)
    /// Held remote touch, built by `SimulatorDisplay.message(for:)` with its coordinates.
    case tvRemoteTouch

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

/// Raw SimDigitizerInputView.TouchMode values used when trackpad force is unavailable.
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
    var captureDisplayID: UInt32? { get }
    func connectAppDisplay(uniqueID: String) async throws -> any SimulatorDisplay
    var view: NSView { get }
    var usesNativeCanvas: Bool { get }
    var nativeRotationControl: NativeDeviceRotationControl? { get }
    /// The input digitizer, or the loaded plugin's overlay.
    var inputView: NSView { get }
    /// Loaded device-profile plugin, or nil until available. Throws if unusable,
    /// including a plugin from another Xcode installation.
    func userInterfacePlugin() throws -> SimulatorUserInterfacePlugin?
    /// Current CoreSimulator backlight state: 2 on, 1 always-on dimmed, 0 off.
    /// Nil when unavailable.
    var backlightState: Int32? { get }
    /// Posts recording notifications consumed by the device plugin's toolbar.
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
    /// `SimDeviceChrome.images.padding`, or nil when no bezel is visible.
    var chromePadding: NSSize? { get }
    /// Scaled bezel-corner resize areas in view coordinates.
    /// SimulatorKit leaves their clicks for the window to handle.
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
    /// Builds a remote touch message held until its end phase, for `send(_:completion:)`.
    func message(for touch: TVRemoteTouch) throws -> HIDMessage
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
    // Returns recorded routes in CoreSimulator order. Location calls run serially off the main actor.
    func locationScenarios() async throws -> [LocationScenario]
    func clearSimulatedLocation() async throws
    func setLocation(latitude: Double, longitude: Double) async throws
    /// Runs the route a `LocationScenario.name` names.
    func setLocationScenario(_ name: String) async throws
    // Changes the guest keyboard serially off the main actor.
    func setHardwareKeyboardConnected(_ connected: Bool) async throws
    /// Sets the language of the guest's keyboard, such as `en` or `ja`.
    func setKeyboardLanguage(_ language: String) async throws
    /// Connects to the device's pasteboard service, managing `pasteboard`;
    /// `events` receives the connection's callbacks.
    func connectPasteboard(_ pasteboard: NSPasteboard,
                           events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) throws -> any SimulatorPasteboard
    /// Connects to the device's audio route port. `changed` runs on the main
    /// actor after each change the port reports, until it disconnects.
    func connectAudioRoutes(changed: @escaping @MainActor (AudioRouteChange) -> Void) throws -> any SimulatorAudioRoutes
    /// Observes the existing or subsequently connected TVOut screen on the main actor.
    /// Each connection reports property changes through `changed` until disconnected.
    /// Releasing the token ends reports except queued callbacks; nil means no adapter.
    func registerForExternalScreen(
        changed: @escaping @MainActor () -> Void,
        found: @escaping @MainActor (Result<any SimulatorExternalScreen, any Error>) -> Void
    ) throws -> AnyObject?
    func setChromeVisible(_ visible: Bool)
    func setKeyboardEnabled(_ enabled: Bool)
    /// Controls whether digitizer scrolling reaches the device's crown or dial.
    func setSupportsScrolling(_ supports: Bool)
    /// Sets and posts `com.apple.UIKit.SimulatorWantsEdgeSwipes`.
    /// When enabled, UIKit requires digitizer-marked edge starts; otherwise near-edge touches suffice.
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

extension SimulatorDisplay {
    var usesNativeCanvas: Bool { false }
    var nativeRotationControl: NativeDeviceRotationControl? { nil }
    var captureDisplayID: UInt32? { nil }
    func connectAppDisplay(uniqueID: String) async throws -> any SimulatorDisplay {
        throw HostError.unavailable("This display cannot connect to the app resizing screen.")
    }
}

@MainActor
final class SimulatorConnection: SimulatorDisplay {
    let view: NSView
    /// `SimDisplayView.digitizerView`.
    private let digitizerView: NSView?
    /// The display's user-interface plugin, once found.
    private var plugin: SimulatorUserInterfacePlugin?
    private let runtime: SimulatorRuntime
    private let chromeView: NSView?
    private let nativeCanvas: NativeDeviceCanvas?
    private var nativeScale: CGFloat = 1
    var usesNativeCanvas: Bool { nativeCanvas != nil }
    var nativeRotationControl: NativeDeviceRotationControl? { nativeCanvas?.rotationControl }
    private let device: SimulatorDevice
    private let buttonTarget: UInt32
    let captureDisplayID: UInt32?
    private var hidClient: AnyObject?
    private var disconnected = false
    var onPropertiesChange: (() -> Void)?
    private var screenEvents: NativeSwiftValue?
    private let screen: AnyObject

    init(device: SimulatorDevice, screen: (identifier: UInt32, object: AnyObject), runtime: SimulatorRuntime,
         nativeCanvas: NativeDeviceCanvas? = nil) throws {
        self.nativeCanvas = nativeCanvas
        self.device = device
        self.runtime = runtime
        self.screen = screen.object
        captureDisplayID = screen.identifier
        let display = runtime.display
        buttonTarget = try unsafe display.buttonTarget.unsafeInvoke(on: screen.object)
        hidClient = try runtime.input.connect(to: device)
        if let nativeCanvas {
            view = nativeCanvas.view
            view.frame.size = nativeCanvas.naturalSize
            digitizerView = nil
            chromeView = nil
            nativeCanvas.onSizeChange = { [weak self] in self?.onPropertiesChange?() }
            return
        }
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

    func connectAppDisplay(uniqueID: String) async throws -> any SimulatorDisplay {
        // Device Hub waits up to 30 seconds for the same uniqueId in this device's
        // screen adapter. CoreDevice displayId and SimulatorKit screenID differ.
        for _ in 0..<120 {
            try Task.checkCancellation()
            guard isBooted else { throw HostError.unavailable("The simulator disconnected while preparing app resizing.") }
            if let screen = try runtime.display.appScreen(uniqueID: uniqueID, of: device) {
                let connection = try SimulatorConnection(device: device, screen: screen, runtime: runtime)
                connection.setChromeVisible(false)
                return connection
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw HostError.unavailable("Timed out waiting for the app resizing screen.")
    }

    var isBooted: Bool { !disconnected && device.state == 3 }

    var inputView: NSView { nativeCanvas?.inputView ?? plugin?.overlayView ?? digitizerView ?? view }

    func userInterfacePlugin() throws -> SimulatorUserInterfacePlugin? {
        guard nativeCanvas == nil else { return nil }
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

    // Read properties directly: SimDisplayView.backlightState lags until its change callback.
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
        if nativeCanvas != nil { return nativeScale }
        return read("read the display scale", otherwise: 0) { try unsafe runtime.display.renderScale.unsafeInvoke(on: view) }
    }

    func setRenderScale(_ scale: CGFloat) {
        if let nativeCanvas { nativeScale = scale; nativeCanvas.setZoom(scale); return }
        perform("scale the display") { try unsafe runtime.display.setRenderScale.unsafeInvoke(on: view, scale) }
        view.invalidateIntrinsicContentSize()
    }

    func size(for scale: CGFloat) -> NSSize {
        if let nativeCanvas { return NSSize(width: nativeCanvas.naturalSize.width * scale, height: nativeCanvas.naturalSize.height * scale) }
        return read("measure the display", otherwise: .zero) { try unsafe runtime.display.sizeForScale.unsafeInvoke(on: view, scale) }
    }

    func scale(for size: NSSize) -> CGFloat {
        if let nativeCanvas { return min(size.width / nativeCanvas.naturalSize.width, size.height / nativeCanvas.naturalSize.height) }
        return read("measure the display", otherwise: 0) { try unsafe runtime.display.scaleForSize.unsafeInvoke(on: view, size) }
    }

    var screenScale: CGFloat? {
        read("read the screen scale", otherwise: nil) { try unsafe runtime.display.screenScale.unsafeInvoke(on: screen) }
    }

    var displayClass: UInt16? {
        read("read the display class", otherwise: nil) { try unsafe runtime.display.displayClass.unsafeInvoke(on: screen) }
    }

    var chromePadding: NSSize? {
        guard let chromeView else { return nil }
        let display = runtime.display
        return read("read the device bezel", otherwise: nil) {
            guard let chrome = try unsafe display.chrome.unsafeInvoke(on: chromeView)
                .copyEnumPayloadAndWait(forCase: "some") else { return nil }
            return try unsafe display.chromeImagesPadding.unsafeInvoke(on: display.chromeImages.unsafeInvoke(on: chrome))
        }
    }

    var resizeRects: [DisplayResizeRect] {
        guard nativeCanvas == nil else { return [] }
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
        guard nativeCanvas == nil else { return }
        perform("show resize cursors") { try unsafe runtime.display.showResizeCursors.unsafeInvoke(on: view, shows) }
    }

    var guestInterfaceAngle: Double? {
        guard nativeCanvas == nil, !disconnected,
              let properties = try? unsafe runtime.display.screenProperties.unsafeInvoke(on: screen),
              let orientation = try? unsafe ABIRuntime.shared.object(properties)
                .resolveAndWait(.objc(.method("uiOrientation", as: (() -> UInt32).self))).unsafeInvoke()
        else { return nil }
        return SimScreenUIOrientation.displayAngle(orientation)
    }

    func message(for input: HIDInput, _ state: HIDState) throws -> HIDMessage {
        try runtime.input.message(input, state, target: buttonTarget)
    }

    func send(_ message: HIDMessage, completion: (@MainActor (Error?) -> Void)?) throws {
        if let nativeCanvas {
            let usage: (page: Int, usage: Int)? = switch message.input {
            case .button(.home): (0x0c, 0x40)
            case .button(.lock): (0x0c, 0x30)
            case .usage(let page, let code): (Int(page), Int(code))
            default: nil
            }
            if let usage {
                try nativeCanvas.sendButton(usagePage: usage.page, usage: usage.usage,
                    state: message.state == .down ? .down : .up)
                completion?(nil)
                return
            }
        }
        guard let hidClient else { throw HostError.operation("Simulator input is disconnected") }
        try runtime.input.send(message, client: hidClient, completion: completion)
    }

    func message(for touch: TVRemoteTouch) throws -> HIDMessage {
        HIDMessage(input: .tvRemoteTouch, state: touch.phase == .ended ? .up : .down,
                   pointer: try runtime.input.message(for: touch))
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
    func connectAudioRoutes(changed: @escaping @MainActor (AudioRouteChange) -> Void) throws -> any SimulatorAudioRoutes {
        try runtime.audio.connect(to: device, changed: changed)
    }
    func registerForExternalScreen(
        changed: @escaping @MainActor () -> Void,
        found: @escaping @MainActor (Result<any SimulatorExternalScreen, any Error>) -> Void
    ) throws -> AnyObject? {
        try runtime.display.registerForExternalScreens(of: device) { [device, runtime] screen in
            found(Result {
                try SimulatorExternalScreenConnection(device: device, screen: try screen.get(), runtime: runtime,
                                                      changed: changed)
            })
        }
    }
    func setChromeVisible(_ visible: Bool) {
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
    func setKeyboardEnabled(_ enabled: Bool) {
        guard nativeCanvas == nil, !disconnected, let keyboard = object_getIvar(view, runtime.display.keyboardDelegate) else { return }
        perform("enable keyboard input") {
            try unsafe runtime.display.setKeyboardEnabled.unsafeInvoke(on: keyboard as AnyObject, enabled)
        }
    }
    func setSupportsScrolling(_ supports: Bool) {
        guard !disconnected, let digitizerView else { return }
        perform("enable scrolling") {
            try unsafe runtime.display.setSupportsScrolling.unsafeInvoke(on: digitizerView, supports)
        }
    }
    func setWantsEdgeSwipes(_ wants: Bool) {
        guard nativeCanvas == nil, !disconnected else { return }
        perform("tell the device whether edge swipes start on the bezel") {
            let name = "com.apple.UIKit.SimulatorWantsEdgeSwipes"
            try device.setNotificationState(name, to: wants ? 1 : 0)
            try device.postNotification(name)
        }
    }
    func setSupportsTouchPressure(_ supports: Bool) {
        guard !disconnected, let digitizerView else { return }
        perform("enable touch pressure") {
            try unsafe runtime.display.setSupportsTouchPressure.unsafeInvoke(on: digitizerView, supports)
        }
    }
    func setUsesTrackpadForce(_ uses: Bool) {
        guard !disconnected, let digitizerView else { return }
        perform("use the trackpad's force") {
            try unsafe runtime.display.setUsesTrackpadForce.unsafeInvoke(on: digitizerView, uses)
        }
    }
    func setSimulatedTouchMode(_ mode: SimulatedTouchMode) {
        guard !disconnected, let digitizerView else { return }
        perform("set the touch pressure") {
            try unsafe runtime.display.setSimulatedTouchMode.unsafeInvoke(on: digitizerView, mode.rawValue)
        }
    }
    func setTouchIndicator(_ indicator: TouchIndicator, shown: Bool) {
        guard !disconnected, let digitizerView else { return }
        let display = runtime.display
        perform("show touch indicators") {
            let options = try unsafe display.drawOptionRawValue.unsafeInvoke(on: display.drawOptions.unsafeInvoke(on: digitizerView))
            let option = display.drawOption(for: indicator)
            try unsafe display.setDrawOptions.unsafeInvoke(
                on: digitizerView, display.makeDrawOption.unsafeInvoke(shown ? options | option : options & ~option))
        }
    }
    func setRotation(degrees: Double) {
        guard nativeCanvas == nil else { return }
        perform("rotate the display") {
            try unsafe runtime.display.rotation.unsafeInvoke(on: view, Measurement(value: degrees, unit: .degrees))
        }
        view.invalidateIntrinsicContentSize()
    }
    func beginResize() { guard nativeCanvas == nil else { return }; perform("begin resizing") { try unsafe runtime.display.beginResize.unsafeInvoke(on: view) } }
    func resize(to size: NSSize) {
        if nativeCanvas != nil { setRenderScale(scale(for: size)); return }
        perform("resize the display") { try unsafe runtime.display.resize.unsafeInvoke(on: view, size) }
        view.invalidateIntrinsicContentSize()
    }
    func endResize() { guard nativeCanvas == nil else { return }; perform("end resizing") { try unsafe runtime.display.endResize.unsafeInvoke(on: view) } }
    func disconnect() {
        guard !disconnected else { return }
        disconnected = true
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
