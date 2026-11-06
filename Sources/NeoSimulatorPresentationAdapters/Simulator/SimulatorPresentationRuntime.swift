import ABIBridge
import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import NeoSimulatorNative
import ObjectiveC
import ObservationBridge
import Synchronization

/// What presents one Xcode's devices: its CoreSimulator context with the process's one UI toolkit and the SimulatorKit
/// members bound to it.
@MainActor
package final class SimulatorPresentationRuntime {
    private static var preparations: [URL: Task<SimulatorPresentationRuntime, any Error>] = [:]
    package let io: SimulatorIORuntime
    /// The Xcode that owns this device context and its command-line tools.
    package var xcodeURL: URL { io.xcodeURL }
    /// The process's fixed SimulatorKit and user-interface factory.
    package let uiXcodeURL: URL
    package let display: SimulatorDisplayInterface
    package let input: SimulatorInputInterface
    package let pasteboard: SimulatorPasteboardInterface
    package var audio: SimulatorAudioInterface { io.audio }

    /// Joins a context's in-flight preparation while its native values stay on the main actor. A toolkit other than the
    /// process's fails, also when preparations of different contexts run together.
    package static func load(xcodeURL: URL, uiXcodeURL: URL? = nil) async throws -> SimulatorPresentationRuntime {
        try await load(io: try await SimulatorIORuntime.load(xcodeURL: xcodeURL), uiXcodeURL: uiXcodeURL)
    }

    package static func load(io: SimulatorIORuntime, uiXcodeURL: URL? = nil) async throws -> SimulatorPresentationRuntime {
        try Task.checkCancellation()
        let source = io.xcodeURL
        if let preparation = preparations[source] {
            let runtime = try await CoreDeviceRuntime.preparedValue(of: preparation)
            if let requestedUI = uiXcodeURL?.resolvingSymlinksInPath(), runtime.uiXcodeURL != requestedUI {
                throw DeviceIOError.runtime("simulator-runtime", .toolkitAlreadyLoaded(from: runtime.uiXcodeURL))
            }
            try Task.checkCancellation()
            return runtime
        }
        let preparation = Task {
            do { return try await SimulatorPresentationRuntime(io: io, uiXcodeURL: uiXcodeURL) }
            catch { preparations[source] = nil; throw error }
        }
        preparations[source] = preparation
        let runtime = try await CoreDeviceRuntime.preparedValue(of: preparation)
        try Task.checkCancellation()
        return runtime
    }

    private init(io: SimulatorIORuntime, uiXcodeURL: URL?) async throws {
        self.io = io
        self.uiXcodeURL = try await CoreDeviceRuntime.loading("simulator-runtime") { [xcodeURL = io.xcodeURL] in
            try await NativeFrameworks.loadUIToolkit(requested: uiXcodeURL, context: xcodeURL)
        }
        try await PortableObservationTracking.prepare()
        let runtime = ABIRuntime.shared
        display = try await SimulatorDisplayInterface(runtime: runtime)
        input = try await SimulatorInputInterface(runtime: runtime)
        pasteboard = try await SimulatorPasteboardInterface(runtime: runtime)
        try await validateLoadedImages()
    }

    /// Keeps the UI toolkit fixed while allowing plugins belonging to an opened device context.
    package func validateLoadedImages() async throws {
        try await CoreDeviceRuntime.loading("simulator-runtime") { try await NativeFrameworks.validateLoadedImages() }
    }

    private static var touchPreparation: Task<SimulatorTouchInterface, any Error>?

    /// The SimulatorKit members that move a digitizer's touches to a device's native touchscreen, prepared once for
    /// the process's SimulatorKit. A failure to prepare them stays for the process.
    package func touchInterface() async throws -> SimulatorTouchInterface {
        let preparation = Self.touchPreparation ?? Task { try await SimulatorTouchInterface(runtime: .shared) }
        Self.touchPreparation = preparation
        return try await CoreDeviceRuntime.preparedValue(of: preparation)
    }
}

/// SimulatorKit display members and the IDEPlaygroundSimulator display factory.
@MainActor
package struct SimulatorDisplayInterface {
    let screen: NativeObjCMethod<AnyObject?>
    let isDefault: NativeObjCMethod<Bool>
    let isCarPlay: NativeObjCMethod<Bool>
    let buttonTarget: NativeSwiftMethod<() -> UInt32>
    package typealias ScreenEventHandler = NativeSwiftClosure<(NativeSwiftBorrowedValue, NativeSwiftBorrowedValue) -> Void>
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
    package let screenAdapter = ScreenAdapterGetter()
    /// Screens currently published by the device's screen adapter.
    let adapterScreens: NativeSwiftMethod<() -> [UInt32: NativeSwiftValue]>
    package typealias AdapterEventHandler = NativeSwiftClosure<(NativeSwiftValue) -> Void>
    /// Screen-adapter registration. Releasing the token ends callbacks except those already queued.
    let registerAdapterEvents: NativeSwiftMethod<(UInt32?, DispatchQueue, AdapterEventHandler) -> AnyObject>
    /// Messages to CoreSimDeviceIO's screen proxies: `SimScreenProperties`
    /// and `SimScreenMode`.
    package let screenMessages = ProxyMessages()
    /// Default CarPlay properties: `SimCarPlayPropertyKeyStark` and `SimCarPlayPropertyKeyHasTouchScreen`.
    package let carPlayProperties: NSDictionary
    package let factoryClass: AnyClass
    let createDisplay: NativeObjCMethod<NSView?, AnyObject, UInt32>
    let showChrome: NativeSwiftMethod<(Bool) -> Void>
    let chromeView: NativeSwiftMethod<() -> NSView>
    let digitizerView: NativeSwiftMethod<() -> NSView>
    /// `SimDisplayView.renderableView`, which shows the framebuffer: the screen without its bezel.
    let renderableView: NativeSwiftMethod<() -> NSView>
    let renderScale: NativeSwiftMethod<() -> CGFloat>
    let setRenderScale: NativeSwiftMethod<(CGFloat) -> Void>
    /// `SimDisplayView.size(for:)`.
    let sizeForScale: NativeSwiftMethod<(CGFloat) -> CGSize>
    /// `SimDisplayView.scale(for:)`.
    let scaleForSize: NativeSwiftMethod<(CGSize) -> CGFloat>
    let rotation: NativeSwiftMethod<(Measurement<UnitAngle>) -> Void>
    let disconnect: NativeSwiftMethod<(NativeSwiftClosure<() -> Void>) -> Void>
    let beginResize: NativeSwiftMethod<() -> Void>
    let endResize: NativeSwiftMethod<() -> Void>
    /// `SimDisplayView.showResizeCursors`.
    let showResizeCursors: NativeSwiftMethod<(Bool) -> Void>
    let chromeState: NativeSwiftType
    let setChromeState: NativeSwiftMethod<(NativeSwiftValue) -> Void>
    /// `SimDisplayChromeView.chrome`, an optional `SimDeviceChrome`.
    let chrome: NativeSwiftMethod<() -> NativeSwiftValue?>
    /// `SimDeviceChrome.images`.
    let chromeImages: NativeSwiftMethod<() -> NativeSwiftValue>
    /// `SimDeviceChrome.Images.padding`.
    let chromeImagesPadding: NativeSwiftMethod<() -> CGSize>
    let setKeyboardEnabled: NativeSwiftMethod<(Bool) -> Void>
    package let keyboardDelegate: Ivar
    /// `SimDisplayView._userInterfacePlugin` has no getter and stores one object.
    /// SimulatorKit loads it while connecting a device with a user-interface profile.
    package let userInterfacePlugin: Ivar
    /// Messages to a plugin, whose class its bundle provides only once loaded;
    /// `SimDeviceUserInterfacePlugin` must declare them.
    package let pluginMessages = ProxyMessages()
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

    package init(runtime: ABIRuntime) async throws {
        guard let screenClass = NSClassFromString("SimulatorKit.SimDeviceScreen"),
            let factoryClass = NSClassFromString("IDEPlaygroundSimulator.IDESimulatorPlaygroundUntil"),
            let displayViewClass = NSClassFromString("SimulatorKit.SimDisplayView")
        else {
            throw SimulatorError.unavailable("SimulatorKit display classes are unavailable")
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
                throw SimulatorError.unavailable("Required private protocol \(name) is unavailable")
            }
            for selector in selectors
            where unsafe protocol_getMethodDescription(declared, NSSelectorFromString(selector), true, true).name == nil {
                throw SimulatorError.unavailable("\(name) does not declare \(selector)")
            }
        }
        func carPlayKey(_ name: String) async throws -> String {
            let symbol = try await runtime.resolve(.c(.symbol(name, kind: .data)))
            guard let key = unsafe symbol.withUnsafeAddress({
                unsafe $0.load(as: Unmanaged<NSString>?.self)?.takeUnretainedValue() as String?
            }) else {
                throw SimulatorError.unavailable("\(name) has no value")
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
        renderableView = try await view.resolve(.swift(.getter(
            "renderableView.getter : SimulatorKit.SimDisplayRenderableView", as: (() -> NSView).self)))
        renderScale = try await view.resolve(.swift(.getter("renderScale", as: (() -> CGFloat).self)))
        setRenderScale = try await view.resolve(.swift(.setter("renderScale", as: ((CGFloat) -> Void).self)))
        sizeForScale = try await view.resolve(.swift(.method("size(for:)", as: ((CGFloat) -> CGSize).self)))
        scaleForSize = try await view.resolve(.swift(.method("scale(for:)", as: ((CGSize) -> CGFloat).self)))
        rotation = try await view.resolve(.swift(.setter("deviceRotation", as: ((Measurement<UnitAngle>) -> Void).self)))
        disconnect = try await view.resolve(.swift(.method(
            "disconnect(completion: (() -> ())?) -> ()",
            as: ((NativeSwiftClosure<() -> Void>) -> Void).self)))
        beginResize = try await view.resolve(.swift(.method("beginResize()", as: (() -> Void).self)))
        endResize = try await view.resolve(.swift(.method("endResize()", as: (() -> Void).self)))
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
        // Prepare Optional projection once; bezel geometry is read during every layout pass.
        chrome = try await chromeViewType.resolve(.swift(.getter(
            "chrome.getter : SimulatorKit.SimDeviceChrome?", as: (() -> NativeSwiftValue?).self,
            valueABIs: [optionalChrome: try .opaque(named: optionalChrome.name)])))
        chromeImages = try await deviceChrome.resolve(.swift(.getter(
            "images.getter : SimulatorKit.SimDeviceChrome.Images", as: (() -> NativeSwiftValue).self,
            valueABIs: [images: try .opaque(named: images.name)], receiverABI: .opaque(named: deviceChrome.name))))
        chromeImagesPadding = try await images.resolve(.swift(.getter(
            "padding.getter : __C.CGSize", as: (() -> CGSize).self, receiverABI: .opaque(named: images.name))))
        setKeyboardEnabled = try await runtime.resolve(.swift(.type("SimulatorKit.SimKeyboardInputDefaultDelegate")))
            .resolve(.swift(.setter("isEnabled", as: ((Bool) -> Void).self)))
        guard let keyboardDelegate = class_getInstanceVariable(displayViewClass, "_defaultKeyboardDelegate") else {
            throw SimulatorError.unavailable("\(displayViewClass) does not provide _defaultKeyboardDelegate")
        }
        self.keyboardDelegate = keyboardDelegate
        guard let userInterfacePlugin = class_getInstanceVariable(displayViewClass, "_userInterfacePlugin") else {
            throw SimulatorError.unavailable("\(displayViewClass) does not provide _userInterfacePlugin")
        }
        self.userInterfacePlugin = userInterfacePlugin
        let pluginProtocol = "_TtP12SimulatorKit28SimDeviceUserInterfacePlugin_"
        guard let declared = objc_getProtocol(pluginProtocol) else {
            throw SimulatorError.unavailable("Required private protocol \(pluginProtocol) is unavailable")
        }
        for selector in SimulatorUserInterfacePlugin.selectors
        where unsafe protocol_getMethodDescription(declared, NSSelectorFromString(selector), true, true).name == nil {
            throw SimulatorError.unavailable("\(pluginProtocol) does not declare \(selector)")
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
    package func drawOption(for indicator: TouchIndicator) -> Int {
        switch indicator {
        case .singleTouches: touchIndicatorOptions.singleTouches
        case .pinches: touchIndicatorOptions.pinches
        case .pinchPivotPoint: touchIndicatorOptions.pinchPivotPoint
        case .edgeGestures: touchIndicatorOptions.edgeGestures
        }
    }

    /// The device's default non-CarPlay screen, or nil while it is not ready. A screen that cannot be read does not hide
    /// a later one; when none is found, the failure says why.
    package func defaultScreen(of device: SimulatorDevice) throws -> (identifier: UInt32, object: AnyObject)? {
        // The synchronous screen initializer waits for missing IDs and blocks AppKit during boot.
        guard let adapter = try screenAdapter.adapter(of: device.handle.object) else { return nil }
        var failure: (any Error)?
        for (identifier, value) in try unsafe adapterScreens.unsafeInvoke(on: adapter).sorted(by: { $0.key < $1.key }) {
            do {
                let screen = try value.withCopy { $0 as AnyObject }
                _ = try unsafe self.screen.unsafeInvoke(on: screen)
                guard try unsafe isDefault.unsafeInvoke(on: screen),
                      try unsafe !isCarPlay.unsafeInvoke(on: screen) else { continue }
                return (identifier, screen)
            } catch { failure = error }
        }
        if let failure { throw failure }
        return nil
    }

    package func appScreen(uniqueID: String, of device: SimulatorDevice) throws -> (identifier: UInt32, object: AnyObject)? {
        guard let adapter = try screenAdapter.adapter(of: device.handle.object) else { return nil }
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
    package static let externalScreenType: UInt64 = 1

    /// Observes connected TVOut screens on the main queue, including future connections.
    /// Releasing the token ends reports except those already queued; nil means no adapter.
    package func registerForExternalScreens(
        of device: SimulatorDevice,
        found: @escaping @MainActor (Result<(identifier: UInt32, object: AnyObject), any Error>) -> Void
    ) throws -> AnyObject? {
        guard let adapter = try screenAdapter.adapter(of: device.handle.object) else { return nil }
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
package final class ScreenAdapterGetter {
    private var getter: NativeSwiftMethod<() -> AnyObject?>?

    /// Resolves the extension before synchronous screen enumeration or registration starts.
    package func prepare(for device: AnyObject) async throws {
        guard getter == nil else { return }
        getter = try await ABIRuntime.shared.object(device).resolve(.swift(.getter(
            "(extension in SimulatorKit):__C.SimDevice.screenAdapter.getter : SimulatorKit.SimDeviceScreenAdapter?",
            as: (() -> AnyObject?).self))).method
    }

    /// The device's `SimDeviceScreenAdapter`, which SimulatorKit keeps for
    /// the device's lifetime, or nil when it has none.
    package func adapter(of device: AnyObject) throws -> AnyObject? {
        let getter = try self.getter ?? ABIRuntime.shared.object(device).resolveAndWait(.swift(.getter(
            "(extension in SimulatorKit):__C.SimDevice.screenAdapter.getter : SimulatorKit.SimDeviceScreenAdapter?",
            as: (() -> AnyObject?).self))).method
        self.getter = getter
        return try unsafe getter.unsafeInvoke(on: device)
    }
}

/// Caches no-argument Objective-C messages by proxy or plugin class.
@MainActor
package final class ProxyMessages {
    private var methods: [String: Any] = [:]

    package func send<Result>(_ selector: String, to object: AnyObject, as type: Result.Type = Result.self) throws -> Result {
        let key = "\(ObjectIdentifier(Swift.type(of: object))) \(selector)"
        let method = try methods[key] as? NativeObjCMethod<Result> ?? ABIRuntime.shared.object(object)
            .resolveAndWait(.objc(.method(selector, as: (() -> Result).self))).method
        methods[key] = method
        return try unsafe method.unsafeInvoke(on: object)
    }
}

/// The selected Xcode's device-profile plugin. SimulatorKit owns its input overlay;
/// the host installs its toolbar and forwards commands through the responder chain.
package struct SimulatorUserInterfacePlugin {
    /// The messages the host sends to a plugin.
    package static let selectors = ["overlayView", "toolbar"]

    package let overlayView: NSView?
    package let toolbar: NSToolbar?
}

/// The SimulatorKit HID client used for hardware buttons and HID usages.
@MainActor
package struct SimulatorInputInterface {
    package typealias Completion = @convention(block) (NSError?) -> Void

    package let clientClass: AnyClass
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
    package static let tvRemoteButtonTarget: UInt32 = 0x15
    package static let tvRemoteTouchTarget: UInt32 = 0x16

    package init(runtime: ABIRuntime) async throws {
        guard let clientClass = NSClassFromString("SimulatorKit.SimDeviceLegacyHIDClient") else {
            throw SimulatorError.unavailable("Required private class SimulatorKit.SimDeviceLegacyHIDClient is unavailable")
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
        else { throw SimulatorError.operation("Could not allocate simulator input") }
        let raw = UnsafeMutableRawPointer(message)
        defer { free(raw) }
        let field = TrackpadMessage.self
        guard malloc_size(raw) >= field.size,
              raw.load(fromByteOffset: field.eventSizeOffset, as: UInt32.self) == field.eventSize,
              raw.load(fromByteOffset: field.eventCountOffset, as: UInt8.self) == field.eventCount,
              field.eventMasks.allSatisfy({ raw.load(fromByteOffset: $0, as: UInt32.self) == field.positionMask }),
              field.touchFlags.allSatisfy({ raw.load(fromByteOffset: $0, as: UInt32.self) == 1 })
        else {
            throw SimulatorError.unavailable(
                "IndigoHIDMessageForTrackpadMoveEvent builds a message the Apple TV Remote's touch surface does not know")
        }
    }

    /// Returns the host keyboard type as the byte required by SimDevice, throwing on overflow.
    package func currentKeyboardType() throws -> UInt8 {
        let type = try unsafe keyboardType.unsafeInvoke()
        guard let byte = UInt8(exactly: type) else {
            throw SimulatorError.operation("SimulatorKit reported keyboard type \(type), which the device cannot take.")
        }
        return byte
    }

    package func connect(to device: SimulatorDevice) async throws -> WorkerOwned<AnyObject> {
        nonisolated(unsafe) let makeClient = makeClient, clientClass = clientClass, object = device.handle.object
        let channel = device.channel
        return try await channel.read("connect the device's input") {
            guard let instance = allocate(clientClass) else {
                throw SimulatorError.unavailable("Could not allocate simulator input")
            }
            return WorkerOwned(try unsafe makeClient.unsafeInvoke(on: instance, object), channel: channel)
        }
    }

    /// Device buttons use states 1/2; Apple TV Remote buttons use their own target and states 1/0.
    package func message(_ input: HIDInput, _ state: HIDState, target: UInt32) throws -> HIDMessage {
        let message = switch input {
        case .button(let button): try unsafe messageForButton.unsafeInvoke(button.rawValue, state.rawValue, target)
        case .usage(let page, let usage): try unsafe messageForUsage.unsafeInvoke(target, page, usage, state.rawValue)
        case .tvRemote(let button):
            try unsafe messageForButton.unsafeInvoke(button.rawValue, state == .down ? 1 : 0, Self.tvRemoteButtonTarget)
        case .tvRemoteTouch: preconditionFailure("A touch's messages come from message(for:), which takes its point")
        }
        guard let message else { throw SimulatorError.operation("Could not allocate simulator input") }
        return HIDMessage(input: input, state: state, pointer: message)
    }

    /// Sends a message. SimulatorKit reports delivery to `completion` on the
    /// main queue.
    package func send(_ hidMessage: HIDMessage, client: AnyObject, completion: (@MainActor (Error?) -> Void)?) throws {
        try send(hidMessage.take(), client: client, completion: completion)
    }

    /// Builds and patches a remote touch message using the layout validated at startup.
    /// The caller must send or free the message.
    package func message(for touch: TVRemoteTouch) throws -> OpaquePointer {
        guard let message = try unsafe messageForTrackpadMove.unsafeInvoke(touch.point, Self.tvRemoteTouchTarget) else {
            throw SimulatorError.operation("Could not allocate simulator input")
        }
        let raw = UnsafeMutableRawPointer(message)
        for (offset, value) in TrackpadMessage.changes(for: touch.phase) {
            raw.storeBytes(of: value, toByteOffset: offset, as: UInt32.self)
        }
        return message
    }

    /// Sends a watch gesture, a single message without down and up events.
    package func send(_ gesture: WatchGesture, client: AnyObject, completion: @escaping @MainActor (Error?) -> Void) throws {
        guard let message = try unsafe messageForWatchGesture.unsafeInvoke(gesture.rawValue) else {
            throw SimulatorError.operation("Could not allocate simulator input")
        }
        try send(message, client: client, completion: completion)
    }

    /// Sends the CarPlay HID-service change; completion reports send status, not guest creation.
    /// The guest creates the service only once.
    package func sendCarPlayService(connected: Bool, hasTouchScreen: Bool, client: AnyObject,
                            completion: @escaping @MainActor (Error?) -> Void) throws {
        let message = try unsafe connected ? createCarPlayService.unsafeInvoke(hasTouchScreen)
                                           : removeCarPlayService.unsafeInvoke()
        guard let message else { throw SimulatorError.operation("Could not allocate simulator input") }
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

/// The SimulatorKit members that give a digitizer's interpreted touches to a device's native touchscreen through a
/// `SimDigitizerInputViewDelegate` whose methods are this host's callbacks.
@MainActor
package struct SimulatorTouchInterface {
    package static let delegateProtocol = "SimulatorKit.SimDigitizerInputViewDelegate"

    /// `SimDigitizerInputView.delegate`, an optional `SimDigitizerInputViewDelegate` that the view keeps weakly.
    let delegate: NativeSwiftMethod<() -> NativeSwiftValue?>
    let setDelegate: NativeSwiftMethod<(NativeSwiftValue?) -> Void>
    /// The conventions of the delegate's resilient event arguments, which are passed indirectly.
    let eventABIs: [NativeSwiftType: NativeType]
    /// `SimDigitizerInputView.TouchEvent`'s `touch1`, `touch2`, `type`, and `edge`.
    private let firstPoint: NativeSwiftMethod<() -> NativeSwiftValue>
    private let secondPoint: NativeSwiftMethod<() -> NativeSwiftValue>
    private let eventType: NativeSwiftMethod<() -> Int>
    private let edge: NativeSwiftMethod<() -> Int>
    /// `SimDigitizerInputView.DeviceUnitPoint`'s coordinates.
    private let x: NativeSwiftMethod<() -> CGFloat>
    private let y: NativeSwiftMethod<() -> CGFloat>

    package init(runtime: ABIRuntime) async throws {
        let digitizer = try await runtime.resolve(.swift(.type("SimulatorKit.SimDigitizerInputView")))
        delegate = try await digitizer.resolve(.swift(.getter("delegate", as: (() -> NativeSwiftValue?).self)))
        setDelegate = try await digitizer.resolve(.swift(.setter("delegate", as: ((NativeSwiftValue?) -> Void).self)))
        let event = try await runtime.resolve(.swift(.type("SimulatorKit.SimDigitizerInputView.TouchEvent")))
        let pressureEvent = try await runtime.resolve(.swift(.type("SimulatorKit.SimDigitizerInputView.PressureEvent")))
        let scrollEvent = try await runtime.resolve(.swift(.type("SimulatorKit.SimDigitizerInputView.ScrollEvent")))
        let point = try await runtime.resolve(.swift(.type("SimulatorKit.SimDigitizerInputView.DeviceUnitPoint")))
        let optionalPoint = try await runtime.resolve(.swift(.type("Swift.Optional", genericArguments: [.type(point)])))
        // SimulatorKit does not export the descriptors of the imported C types of `type` and `edge`, integers returned
        // in a register.
        let int = try await runtime.resolve(.swift(.type("Swift.Int")))
        eventABIs = try Dictionary(uniqueKeysWithValues: [event, pressureEvent, scrollEvent]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        let abis = try eventABIs.merging([point, optionalPoint].map { ($0, try NativeType.opaque(named: $0.name)) }) { $1 }
            .merging([int: .int]) { $1 }
        firstPoint = try await event.resolve(.swift(.getter("touch1", as: (() -> NativeSwiftValue).self,
            valueABIs: abis, receiverABI: abis[event])))
        secondPoint = try await event.resolve(.swift(.getter("touch2", as: (() -> NativeSwiftValue).self,
            valueABIs: abis, receiverABI: abis[event])))
        eventType = try await event.resolve(.swift(.getter("type.getter : __C.NSEventType", as: (() -> Int).self,
            valueABIs: abis, receiverABI: abis[event])))
        edge = try await event.resolve(.swift(.getter("edge.getter : __C.IndigoHIDEdge", as: (() -> Int).self,
            valueABIs: abis, receiverABI: abis[event])))
        x = try await point.resolve(.swift(.getter("x", as: (() -> CGFloat).self, receiverABI: abis[point])))
        y = try await point.resolve(.swift(.getter("y", as: (() -> CGFloat).self, receiverABI: abis[point])))
    }

    /// A touch event of a digitizer, in unit coordinates from the top-left corner of the screen in its own orientation,
    /// which SimulatorKit also sends in its Indigo messages. Nil for an event that changes no touch.
    package func touch(_ event: NativeSwiftBorrowedValue) throws -> NativeDigitizerTouch? {
        guard let phase = Self.phase(try unsafe eventType.unsafeInvoke(on: event)) else { return nil }
        let second = try unsafe secondPoint.unsafeInvoke(on: event).copyEnumPayloadAndWait(forCase: "some")
        return NativeDigitizerTouch(point: try point(unsafe firstPoint.unsafeInvoke(on: event)),
                                    secondPoint: try second.map(point), phase: phase,
                                    edge: Self.edge(try unsafe edge.unsafeInvoke(on: event)))
    }

    /// The touch phase of a touch event's `NSEvent.EventType`. SimulatorKit's own delegate does not read the event's
    /// phase: it passes the type to `IndigoHIDMessageForMouseNSEvent`, which starts a touch for a mouse-down, ends it for
    /// a mouse-up, and moves it for a drag. Other types change no touch.
    package static func phase(_ type: Int) -> RemoteDeviceTouchPhase? {
        switch NSEvent.EventType(rawValue: UInt(bitPattern: type)) {
        case .leftMouseDown, .rightMouseDown: .began
        case .leftMouseUp, .rightMouseUp: .ended
        case .leftMouseDragged, .rightMouseDragged: .moved
        default: nil
        }
    }

    private func point(_ value: NativeSwiftValue) throws -> CGPoint {
        CGPoint(x: try unsafe x.unsafeInvoke(on: value), y: try unsafe y.unsafeInvoke(on: value))
    }

    /// The edge of an `IndigoHIDEdge`. SimulatorKit's digitizer measures a touch's start from each edge of its
    /// unflipped bounds and gives the nearest as 1 for the top, 2 for the left, 3 for the bottom, and 4 for the right.
    /// Other values mark no edge.
    package static func edge(_ rawValue: Int) -> RemoteDeviceTouchEdge {
        switch rawValue {
        case 1: .top
        case 2: .left
        case 3: .bottom
        case 4: .right
        default: .none
        }
    }
}

/// SimPasteboardPlus, which CoreSimulator loads: the host end of a device's
/// pasteboard connection, which Simulator.app and `simctl pbsync` use.
@MainActor
package struct SimulatorPasteboardInterface {
    package let interfaceClass: AnyClass
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
    package let serviceName: String

    package init(runtime: ABIRuntime) async throws {
        guard let interfaceClass = NSClassFromString("SimPasteboardPlus.SimPasteboardInterface"),
              let listenerClass = NSClassFromString("SimPasteboardPlus.SimPasteboardInterfaceListener") else {
            throw SimulatorError.unavailable("SimPasteboardPlus pasteboard classes are unavailable")
        }
        try await self.init(runtime: runtime, interfaceClass: interfaceClass, listenerClass: listenerClass)
    }

    package init(runtime: ABIRuntime, interfaceClass: AnyClass, listenerClass: AnyClass) async throws {
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
    package func connect(to device: SimulatorDevice, managing pasteboard: NSPasteboard,
                 events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) async throws -> SimulatorPasteboardConnection {
        let port = OwnedSendRight(try await device.lookUp(serviceName))
        return try await connect(port, on: device.channel, managing: pasteboard, events: events)
    }

    /// The request owns `port` from here on. Its caller can stop waiting between the channel starting the request and
    /// the worker reaching it, so only the request knows whether the initializer, which consumes the right, will run.
    package func connect(_ port: OwnedSendRight, on channel: SimulatorDeviceChannel, managing pasteboard: NSPasteboard,
                 events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) async throws -> SimulatorPasteboardConnection {
        // The interface calls the delegate on the main queue; the connection keeps it.
        let delegate = SimulatorPasteboardDelegate(events)
        nonisolated(unsafe) let makeInterface = makeInterface, interfaceClass = interfaceClass, pasteboard = pasteboard, target = delegate
        let object = try await channel.read("connect the device's pasteboard") { () throws -> WorkerOwned<AnyObject> in
            guard let instance = allocate(interfaceClass) else {
                throw SimulatorError.unavailable("Could not allocate the simulator's pasteboard connection")
            }
            let right = port.take()
            return WorkerOwned(try unsafe makeInterface.unsafeInvoke(on: instance, right, pasteboard, target, .main), channel: channel)
        }
        return SimulatorPasteboardConnection(object: object, delegate: delegate, interface: self, channel: channel)
    }
}

@MainActor
package final class SimulatorPasteboardConnection: SimulatorPasteboard {
    private let object: WorkerOwned<AnyObject>
    private let delegate: SimulatorPasteboardDelegate
    private let interface: SimulatorPasteboardInterface
    private let channel: SimulatorDeviceChannel

    fileprivate init(object: WorkerOwned<AnyObject>, delegate: SimulatorPasteboardDelegate,
                     interface: SimulatorPasteboardInterface, channel: SimulatorDeviceChannel) {
        self.object = object
        self.delegate = delegate
        self.interface = interface
        self.channel = channel
    }

    package func pull() async throws { try await send("get the device's pasteboard", interface.pull) }
    package func push() async throws { try await send("send the pasteboard to the device", interface.push) }
    package func setAutomaticSync(_ enabled: Bool) async throws {
        try await send("change the device's pasteboard synchronization",
                       enabled ? interface.enableAutomaticSync : interface.disableAutomaticSync)
    }
    package func disconnect() { delegate.events = nil }

    private func send(_ operation: String, _ message: NativeObjCMethod<Void>) async throws {
        nonisolated(unsafe) let message = message
        try await channel.change(operation) { [object] in try unsafe message.unsafeInvoke(on: object.value) }
    }
}

/// Optional SimPasteboardDelegate callbacks arrive on the main queue.
/// The connection does not require declared protocol conformance.
@MainActor
package final class SimulatorPasteboardDelegate: NSObject {
    package var events: ((SimulatorPasteboardEvent) -> Void)?

    package init(_ events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) { self.events = events }

    @objc package func simPasteboardDidBecomeActive(_ interface: AnyObject) { events?(.activated) }

    @objc package func simPasteboardDidLoseConnection(_ interface: AnyObject) { events?(.lostConnection) }

    @objc package func simPasteboardDidApplySnapshot(_ interface: AnyObject, fromHost host: NSUUID, incomingGeneration: Int64,
                                             toPasteboard pasteboard: NSPasteboard, atGeneration generation: Int64) {
        events?(.applied(generation: Int(generation)))
    }

    @objc package func simPasteboardErrorApplyingSnapshot(_ interface: AnyObject, fromHost host: NSUUID, generation: Int64,
                                                  error: NSError, toPasteboard pasteboard: NSPasteboard) {
        events?(.failedToApply(error))
    }

    @objc package func simPasteboardDidChangeAutoNotifyState(_ interface: AnyObject, forPasteboard pasteboard: NSPasteboard,
                                                     toStatus enabled: Bool) {
        events?(.synchronizationChanged(enabled))
    }
}

/// An uninitialized instance for an Objective-C initializer, which consumes it. A request makes it on the worker just
/// before that, so that no request that never runs has one to dispose of.
private func allocate(_ type: AnyClass) -> AnyObject? {
    (type as? NSObject.Type)?.perform(NSSelectorFromString("alloc"))?.takeRetainedValue()
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
