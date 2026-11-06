import ABIBridge
import ObservationBridge
import AppKit
import Darwin
import MachO
import NeoSimulatorDeviceIO
import ObjectiveC
import Synchronization

// SimulatorKit passes rotations as Measurement<UnitAngle>, whose layout only
// its metadata establishes.
extension Measurement: @retroactive ABIBridgeSwiftValue where UnitType == UnitAngle {
    public static var swiftABIType: NativeType { try! .opaque(named: "Measurement") }
}

/// Uses one UI toolkit per process and a separate CoreSimulator context for each Xcode.
@MainActor
package final class SimulatorRuntime {
    private static var loadedUIXcodeURL: URL?
    private static var contextXcodeURLs: Set<URL> = []
    private static var preparations: [URL: Task<SimulatorRuntime, any Error>] = [:]
    /// The Xcode that owns this device context and its command-line tools.
    package let xcodeURL: URL
    /// The process's fixed SimulatorKit and user-interface factory.
    package let uiXcodeURL: URL
    package let coreSimulator: CoreSimulatorInterface
    package let display: SimulatorDisplayInterface
    package let input: SimulatorInputInterface
    package let pasteboard: SimulatorPasteboardInterface
    package let audio: SimulatorAudioInterface

    /// Joins a context's in-flight preparation while its native values stay on the main actor.
    package static func load(xcodeURL: URL, uiXcodeURL: URL? = nil) async throws -> SimulatorRuntime {
        try Task.checkCancellation()
        let source = xcodeURL.resolvingSymlinksInPath()
        if let preparation = preparations[source] {
            let runtime = try await CoreDeviceRuntime.preparedValue(of: preparation)
            if let requestedUI = uiXcodeURL?.resolvingSymlinksInPath(), runtime.uiXcodeURL != requestedUI {
                throw SimulatorError.unavailable("SimulatorKit is already loaded from \(runtime.uiXcodeURL.path)")
            }
            try Task.checkCancellation()
            return runtime
        }
        let preparation = Task {
            defer { preparations[source] = nil }
            let requestedUI = (uiXcodeURL ?? loadedUIXcodeURL ?? source).resolvingSymlinksInPath()
            return try await SimulatorRuntime(xcodeURL: source, uiXcodeURL: requestedUI)
        }
        preparations[source] = preparation
        let runtime = try await CoreDeviceRuntime.preparedValue(of: preparation)
        try Task.checkCancellation()
        return runtime
    }

    private init(xcodeURL: URL, uiXcodeURL: URL) async throws {
        self.xcodeURL = xcodeURL.resolvingSymlinksInPath()
        let requestedUI = uiXcodeURL.resolvingSymlinksInPath()
        if let loaded = Self.loadedUIXcodeURL, loaded != requestedUI {
            throw SimulatorError.unavailable("SimulatorKit is already loaded from \(loaded.path)")
        }
        self.uiXcodeURL = requestedUI
        try Self.load(URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"))
        try Self.load(requestedUI.appendingPathComponent("Contents/SharedFrameworks/SimulatorKit.framework"))
        // Objective-C registration cannot be undone after a later binding failure.
        Self.loadedUIXcodeURL = requestedUI
        try Self.load(requestedUI.appendingPathComponent("Contents/Frameworks/IDEPlaygroundSimulator.framework"))
        Self.contextXcodeURLs.insert(self.xcodeURL)
        try await PortableObservationTracking.prepare()
        let runtime = ABIRuntime.shared
        coreSimulator = try await CoreSimulatorInterface(runtime: runtime)
        display = try await SimulatorDisplayInterface(runtime: runtime)
        input = try await SimulatorInputInterface(runtime: runtime)
        pasteboard = try await SimulatorPasteboardInterface(runtime: runtime)
        audio = try await SimulatorAudioInterface(runtime: runtime)
        try validateLoadedImages()
    }

    package static func creationCatalog(xcodeURL: URL) async throws -> SimulatorCatalog.Snapshot {
        try load(URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"))
        let interface = try await CoreSimulatorInterface(runtime: .shared)
        let set = SimulatorDeviceSet.shared(interface: interface,
                                            developerDirectory: xcodeURL.appendingPathComponent("Contents/Developer").path)
        return try await set.readCatalog()
    }

    private static func load(_ url: URL) throws {
        guard let executable = Bundle(url: url)?.executableURL else {
            throw SimulatorError.unavailable("Missing framework at \(url.path)")
        }
        // Objective-C class registration outlives the handle. Loaded Apple
        // frameworks stay mapped for the lifetime of the host process.
        guard dlopen(executable.path, RTLD_NOW | RTLD_LOCAL) != nil else {
            let detail = dlerror().map { String(cString: $0) } ?? "Unknown loader error"
            throw SimulatorError.unavailable("Could not load \(executable.path): \(detail)")
        }
    }

    /// Keeps the UI toolkit fixed while allowing plugins belonging to an opened device context.
    package func validateLoadedImages() throws {
        let prefix = uiXcodeURL.path + "/"
        for index in 0..<_dyld_image_count() {
            guard let pointer = _dyld_get_image_name(index) else { continue }
            let path = URL(fileURLWithPath: String(cString: pointer)).resolvingSymlinksInPath().path
            if path.contains("/DeviceHub.app/") {
                throw SimulatorError.unavailable("Forbidden Device Hub component is loaded: \(path)")
            }
            if (path.contains("/SimulatorKit.framework/") || path.contains("/IDEPlaygroundSimulator.framework/")),
               !path.hasPrefix(prefix) {
                throw SimulatorError.unavailable("Private simulator code came from a different Xcode: \(path)")
            }
            if path.contains(".simdeviceui/"), !path.hasPrefix(prefix),
               !Self.contextXcodeURLs.contains(where: { path.hasPrefix($0.path + "/") }) {
                throw SimulatorError.unavailable("The simulator UI plugin does not belong to an opened Xcode context: \(path)")
            }
        }
    }

    /// The owner of the default device set, or of the set at `path`.
    package func openDeviceSet(at path: String? = nil) -> SimulatorDeviceSet {
        SimulatorDeviceSet.shared(
            interface: coreSimulator,
            developerDirectory: xcodeURL.appendingPathComponent("Contents/Developer").path, path: path)
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
    package let screen: NativeObjCMethod<AnyObject?>
    package let isDefault: NativeObjCMethod<Bool>
    package let isCarPlay: NativeObjCMethod<Bool>
    package let buttonTarget: NativeSwiftMethod<() -> UInt32>
    package typealias ScreenEventHandler = NativeSwiftClosure<(NativeSwiftBorrowedValue, NativeSwiftBorrowedValue) -> Void>
    /// `SimDeviceScreen.register(types:queue:handler:)`. Releasing the
    /// returned registration ends it.
    package let registerScreenEvents: NativeSwiftMethod<(NativeSwiftValue, DispatchQueue, ScreenEventHandler) -> NativeSwiftValue>
    /// `SimDeviceScreen.ScreenEventTypes.properties`.
    package let screenPropertyEvents: NativeSwiftValue
    /// `SimDeviceScreen.properties`, an `id<SimScreenProperties>`.
    package let screenProperties: NativeSwiftMethod<() -> AnyObject>
    /// `SimDeviceScreen.scale`, the screen's pixels per point.
    package let screenScale: NativeSwiftMethod<() -> CGFloat>
    /// `SimDeviceScreen.displayClass`.
    package let displayClass: NativeSwiftMethod<() -> UInt16>
    /// `SimDevice.screenAdapter`, the device's `SimDeviceScreenAdapter`.
    package let screenAdapter = ScreenAdapterGetter()
    /// Screens currently published by the device's screen adapter.
    package let adapterScreens: NativeSwiftMethod<() -> [UInt32: NativeSwiftValue]>
    package typealias AdapterEventHandler = NativeSwiftClosure<(NativeSwiftValue) -> Void>
    /// Screen-adapter registration. Releasing the token ends callbacks except those already queued.
    package let registerAdapterEvents: NativeSwiftMethod<(UInt32?, DispatchQueue, AdapterEventHandler) -> AnyObject>
    /// Messages to CoreSimDeviceIO's screen proxies: `SimScreenProperties`
    /// and `SimScreenMode`.
    package let screenMessages = ProxyMessages()
    /// Default CarPlay properties: `SimCarPlayPropertyKeyStark` and `SimCarPlayPropertyKeyHasTouchScreen`.
    package let carPlayProperties: NSDictionary
    package let factoryClass: AnyClass
    package let createDisplay: NativeObjCMethod<NSView?, AnyObject, UInt32>
    package let showChrome: NativeSwiftMethod<(Bool) -> Void>
    package let chromeView: NativeSwiftMethod<() -> NSView>
    package let digitizerView: NativeSwiftMethod<() -> NSView>
    /// `SimDisplayView.renderableView`, which shows the framebuffer: the screen without its bezel.
    package let renderableView: NativeSwiftMethod<() -> NSView>
    package let renderScale: NativeSwiftMethod<() -> CGFloat>
    package let setRenderScale: NativeSwiftMethod<(CGFloat) -> Void>
    /// `SimDisplayView.size(for:)`.
    package let sizeForScale: NativeSwiftMethod<(CGFloat) -> CGSize>
    /// `SimDisplayView.scale(for:)`.
    package let scaleForSize: NativeSwiftMethod<(CGSize) -> CGFloat>
    package let rotation: NativeSwiftMethod<(Measurement<UnitAngle>) -> Void>
    package let disconnect: NativeSwiftMethod<(NativeSwiftClosure<() -> Void>) -> Void>
    package let beginResize: NativeSwiftMethod<() -> Void>
    package let endResize: NativeSwiftMethod<() -> Void>
    /// `SimDisplayView.showResizeCursors`.
    package let showResizeCursors: NativeSwiftMethod<(Bool) -> Void>
    package let chromeState: NativeSwiftType
    package let setChromeState: NativeSwiftMethod<(NativeSwiftValue) -> Void>
    /// `SimDisplayChromeView.chrome`, an optional `SimDeviceChrome`.
    package let chrome: NativeSwiftMethod<() -> NativeSwiftValue?>
    /// `SimDeviceChrome.images`.
    package let chromeImages: NativeSwiftMethod<() -> NativeSwiftValue>
    /// `SimDeviceChrome.Images.padding`.
    package let chromeImagesPadding: NativeSwiftMethod<() -> CGSize>
    package let setKeyboardEnabled: NativeSwiftMethod<(Bool) -> Void>
    package let keyboardDelegate: Ivar
    /// `SimDisplayView._userInterfacePlugin` has no getter and stores one object.
    /// SimulatorKit loads it while connecting a device with a user-interface profile.
    package let userInterfacePlugin: Ivar
    /// Messages to a plugin, whose class its bundle provides only once loaded;
    /// `SimDeviceUserInterfacePlugin` must declare them.
    package let pluginMessages = ProxyMessages()
    /// `SimDigitizerInputView.supportScrolling`.
    package let setSupportsScrolling: NativeSwiftMethod<(Bool) -> Void>
    /// `SimDigitizerInputView.supportTouchPressure`.
    package let setSupportsTouchPressure: NativeSwiftMethod<(Bool) -> Void>
    /// `SimDigitizerInputView.useForceTrackpadForPressure`.
    package let setUsesTrackpadForce: NativeSwiftMethod<(Bool) -> Void>
    /// `SimDigitizerInputView.simulatedTouchMode`, a `TouchMode` passed as
    /// its raw value: see `SimulatedTouchMode`.
    package let setSimulatedTouchMode: NativeSwiftMethod<(Int) -> Void>
    /// `SimDigitizerInputView.drawOptions`, a `DrawOption` option set, which
    /// is resilient and so passed indirectly.
    package let drawOptions: NativeSwiftMethod<() -> NativeSwiftValue>
    package let setDrawOptions: NativeSwiftMethod<(NativeSwiftValue) -> Void>
    /// `DrawOption.rawValue` and `DrawOption(rawValue:)`.
    package let drawOptionRawValue: NativeSwiftMethod<() -> Int>
    package let makeDrawOption: NativeSwiftFunction<(Int) -> NativeSwiftValue>
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
        guard let adapter = try screenAdapter.adapter(of: device.object) else { return nil }
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
    package static let externalScreenType: UInt64 = 1

    /// Observes connected TVOut screens on the main queue, including future connections.
    /// Releasing the token ends reports except those already queued; nil means no adapter.
    package func registerForExternalScreens(
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

/// Connection to the device's existing TVOut screen, also used for CarPlay.
/// CoreSimulator exposes no creatable screen properties for devices without one.
@MainActor
package protocol SimulatorExternalScreen: AnyObject {
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
    /// Sets a supported screen mode and powers it on, optionally with CarPlay properties. Completion reports the result
    /// on the main actor. A throw means no completion follows, and that nothing was sent unless it says otherwise.
    func setMode(pixelSize: CGSize, scale: CGFloat, carPlay: Bool,
                 completion: @escaping @MainActor (Error?) -> Void) async throws
    /// `SimScreen setPowerState:0 …`. `completion` receives CoreSimulator's result on the main actor. A throw means no
    /// completion follows, and that nothing was sent unless it says otherwise.
    func powerOff(completion: @escaping @MainActor (Error?) -> Void) async throws
    /// Writes the guest configuration read on mode changes: default CarPlay values or `{stark: 0}`.
    func saveCarPlayConfiguration(carPlay: Bool) throws
    /// Sends a counted CarPlay start/end for `boot`. Completion runs on the main actor.
    /// If the device restarted, no request is sent and completion receives `CarPlayRequestMoot`.
    func setCarPlayEnabled(_ enabled: Bool, inBoot boot: Date?, completion: @escaping @MainActor (Error?) -> Void)
    /// Creates or removes the guest's CarPlay HID service. Completion reports send status on the main actor.
    /// A throw means no completion follows, and that nothing was sent unless it says otherwise.
    func setCarPlayService(connected: Bool, completion: @escaping @MainActor (Error?) -> Void) async throws
    /// A display of the screen from the display factory, for its own window.
    func makeDisplay() async throws -> any SimulatorDisplay
    /// Stops the change reports.
    func disconnect()
}

/// A CarPlay request that was not sent because the device restarted after it
/// was decided for the device's earlier boot.
package struct CarPlayRequestMoot: Error {}

/// The external display of one device, through SimulatorKit's
/// `SimDeviceScreen` and CoreSimDeviceIO's `SimScreen`.
@MainActor
package final class SimulatorExternalScreenConnection: SimulatorExternalScreen {
    /// The messages this connection sends to proxies, by protocol.
    package static let selectors = [
        ("SimScreen", ["setCurrentMode:pixelSize:carPlayProperties:completionQueue:completionHandler:",
                       "setPowerState:completionQueue:completionHandler:", "screenProperties"]),
        ("SimScreenProperties", ["screenID", "powerState", "screenType", "pixelSize", "currentMode",
                                 "supportedScreenModes", "carPlayProperties"]),
        ("SimScreenMode", ["sizeRule", "exactSize", "minSize", "maxSize", "allowedSizes", "preferredUIScale",
                           "refreshRate"]),
    ]

    package typealias Completion = @convention(block) (NSError?) -> Void

    package let screenID: UInt32
    private let device: SimulatorDevice
    /// The `SimDeviceScreen`.
    private let screen: AnyObject
    private let runtime: SimulatorRuntime
    /// The device's native keyboard, which this screen's displays share with its integrated screen.
    private let keyboard: NativeDeviceKeyboard?
    // A proxy's messages go to the device's I/O server, so only the device's worker sends them.
    private nonisolated(unsafe) let setCurrentMode: NativeObjCMethod<Void, AnyObject, CGSize, NSDictionary?, DispatchQueue, Completion>
    private nonisolated(unsafe) let setPowerState: NativeObjCMethod<Void, Int32, DispatchQueue, Completion>
    private var events: NativeSwiftValue?
    /// The HID client that sends the CarPlay service's messages, from the first.
    private var hidClient: WorkerOwned<AnyObject>?

    package init(device: SimulatorDevice, screen: (identifier: UInt32, object: AnyObject), runtime: SimulatorRuntime,
         keyboard: NativeDeviceKeyboard? = nil, changed: @escaping @MainActor () -> Void) throws {
        self.device = device
        self.screen = screen.object
        self.runtime = runtime
        self.keyboard = keyboard
        screenID = screen.identifier
        let display = runtime.display
        guard let simScreen = try unsafe display.screen.unsafeInvoke(on: screen.object) else {
            throw SimulatorError.unavailable("The external display is not connected.")
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

    package var deviceBootDate: Date? { device.lastBootDate }

    package func state() throws -> ExternalScreenState {
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

    package func supportedModes() throws -> [ExternalScreenMode] { try advertisedModes().map(mode) }

    package func setMode(pixelSize size: CGSize, scale: CGFloat, carPlay: Bool,
                 completion: @escaping @MainActor (Error?) -> Void) async throws {
        let simScreen = try connectedScreen()
        // One read of the modes, whose order the choice's index refers to.
        let advertised = try advertisedModes()
        let target: AnyObject? = switch try ExternalScreenMode.choice(
            for: size, scale: scale, current: try state(), among: try advertised.map(mode)) {
        case .current: try runtime.display.screenMessages.send("currentMode", to: try properties(), as: AnyObject?.self)
        case .advertised(let index): advertised[index]
        }
        guard let target else { throw SimulatorError.operation("The external display has no current mode.") }
        nonisolated(unsafe) let message = setCurrentMode, screen = simScreen, mode = target
        nonisolated(unsafe) let properties = carPlay ? runtime.display.carPlayProperties : nil
        nonisolated(unsafe) let completed = Self.completed(completion)
        try await device.channel.change("set the external display's mode") {
            try unsafe message.unsafeInvoke(on: screen, mode, size, properties, .main, completed)
        }
    }

    package func powerOff(completion: @escaping @MainActor (Error?) -> Void) async throws {
        nonisolated(unsafe) let message = setPowerState, screen = try connectedScreen()
        nonisolated(unsafe) let completed = Self.completed(completion)
        try await device.channel.change("turn off the external display") {
            try unsafe message.unsafeInvoke(on: screen, 0, .main, completed)
        }
    }

    package func saveCarPlayConfiguration(carPlay: Bool) throws {
        try CarPlayConfiguration.save(carPlay: carPlay, to: device.extendedDisplayFile())
    }

    package func setCarPlayEnabled(_ enabled: Bool, inBoot boot: Date?, completion: @escaping @MainActor (Error?) -> Void) {
        Task.immediate { [device] in
            do {
                try await device.setCarPlayEnabled(enabled, inBoot: boot)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    package func setCarPlayService(connected: Bool, completion: @escaping @MainActor (Error?) -> Void) async throws {
        let client: WorkerOwned<AnyObject>
        if let hidClient { client = hidClient } else {
            client = try await runtime.input.connect(to: device)
            hidClient = client
        }
        try runtime.input.sendCarPlayService(connected: connected, hasTouchScreen: CarPlayConfiguration.hasTouchScreen,
                                             client: client.value, completion: completion)
    }

    package func makeDisplay() async throws -> any SimulatorDisplay {
        try await SimulatorConnection(device: device, screen: (screenID, screen), runtime: runtime, keyboard: keyboard, ownsKeyboard: false)
    }

    package func disconnect() {
        // Releasing the registration ends the screen events.
        events = nil
    }

    private func properties() throws -> AnyObject {
        try unsafe runtime.display.screenProperties.unsafeInvoke(on: screen)
    }

    private func connectedScreen() throws -> AnyObject {
        guard let simScreen = try unsafe runtime.display.screen.unsafeInvoke(on: screen) else {
            throw SimulatorError.unavailable("The external display is not connected.")
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

    // CoreSimDeviceIO may ignore the completion queue. Bridge back to the main actor explicitly. It also keeps the block
    // after calling it, so the block gives up the completion, which holds this connection and so its device.
    private nonisolated static func completed(_ completion: @escaping @MainActor (Error?) -> Void) -> Completion {
        let pending = Mutex<(@MainActor (Error?) -> Void)?>(completion)
        return { error in
            guard let completion = pending.withLock({ $0.take() }) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
        }
    }
}

/// A native object that its device's worker creates and releases, since CoreSimulator's own teardown of it can wait on
/// the device as its creation does. Dropping the last reference, from anywhere, leaves its release to the worker, so a
/// result that nobody waits for any more or a connection that fails halfway needs nothing further.
package final class WorkerOwned<Value: AnyObject>: @unchecked Sendable {
    private var object: Value?
    private let channel: SimulatorDeviceChannel

    package init(_ object: Value, channel: SimulatorDeviceChannel) {
        self.object = object
        self.channel = channel
    }

    package var value: Value { object! }

    deinit {
        // Nothing else may keep it once the worker has been asked, or the worker's release would not be the last.
        nonisolated(unsafe) var last = object
        object = nil
        channel.cleanUp("release a native connection") { last = nil }
    }
}

/// A Mach send right with one owner at a time. A channel request that captures this owns the right from when it is
/// made: its body takes the right for what consumes it, and a request that never runs releases it along with itself.
package final class OwnedSendRight: Sendable {
    private let name: Mutex<UInt32?>

    package init(_ name: UInt32) { self.name = Mutex(name) }

    /// The right, which the caller then owns. There is one to take.
    package func take() -> UInt32 { name.withLock { $0.take()! } }

    deinit {
        if let name = name.withLock({ $0.take() }) { mach_port_deallocate(mach_task_self_, name) }
    }
}

/// The SimulatorKit HID client used for hardware buttons and HID usages.
@MainActor
package struct SimulatorInputInterface {
    package typealias Completion = @convention(block) (NSError?) -> Void

    package let clientClass: AnyClass
    package let makeClient: NativeObjCMethod<AnyObject, AnyObject>
    package let send: NativeObjCMethod<Void, OpaquePointer, Bool, DispatchQueue?, Completion?>
    /// `IndigoHIDMessageForButton(button, state, target)`.
    package let messageForButton: NativeFunction<OpaquePointer?, UInt32, UInt32, UInt32>
    /// `IndigoHIDMessageForHIDArbitrary(target, usagePage, usage, state)`.
    package let messageForUsage: NativeFunction<OpaquePointer?, UInt32, UInt32, UInt32, UInt32>
    /// `IndigoHIDMessageForWatchGesture(gesture)`.
    package let messageForWatchGesture: NativeFunction<OpaquePointer?, UInt32>
    /// `IndigoHIDGetKeyboardType()`, the type of the Mac's keyboard.
    package let keyboardType: NativeFunction<UInt32>
    /// CarPlay HID service messages target the external display's touch destination.
    package let createCarPlayService: NativeFunction<OpaquePointer?, Bool>
    package let removeCarPlayService: NativeFunction<OpaquePointer?>
    /// `IndigoHIDMessageForTrackpadMoveEvent`: normalized Apple TV Remote touch coordinates.
    package let messageForTrackpadMove: NativeFunction<OpaquePointer?, CGPoint, UInt32>

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
        nonisolated(unsafe) let makeClient = makeClient, clientClass = clientClass, object = device.object
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
    package let delegate: NativeSwiftMethod<() -> NativeSwiftValue?>
    package let setDelegate: NativeSwiftMethod<(NativeSwiftValue?) -> Void>
    /// The conventions of the delegate's resilient event arguments, which are passed indirectly.
    package let eventABIs: [NativeSwiftType: NativeType]
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

/// A touch of a SimulatorKit digitizer, as its delegate receives it.
package struct NativeDigitizerTouch: Equatable {
    package var point: CGPoint
    package var secondPoint: CGPoint?
    package var phase: RemoteDeviceTouchPhase
    package var edge: RemoteDeviceTouchEdge
}

/// SimPasteboardPlus, which CoreSimulator loads: the host end of a device's
/// pasteboard connection, which Simulator.app and `simctl pbsync` use.
@MainActor
package struct SimulatorPasteboardInterface {
    package let interfaceClass: AnyClass
    /// `initWithConnectingToPort:managingPasteboard:delegate:delegateQueue:`.
    package let makeInterface: NativeObjCMethod<AnyObject, UInt32, NSPasteboard, AnyObject?, DispatchQueue?>
    /// Sends the managed pasteboard to the device.
    package let push: NativeObjCMethod<Void>
    /// Asks the device for its pasteboard, which then replaces the managed one.
    package let pull: NativeObjCMethod<Void>
    /// Start and stop the automatic synchronization of Edit ▸ Automatically
    /// Sync Pasteboard.
    package let enableAutomaticSync: NativeObjCMethod<Void>
    package let disableAutomaticSync: NativeObjCMethod<Void>
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

/// A callback about a device's pasteboard connection, as SimPasteboardPlus reports it.
package enum SimulatorPasteboardEvent {
    /// The connection became active: once after connecting, and again each
    /// time the device has taken a push, which `simctl pbsync` waits for.
    case activated
    /// The managed pasteboard was replaced; `generation` is its resulting change count.
    case applied(generation: Int)
    /// Writing the device's pasteboard to the managed pasteboard failed.
    case failedToApply(Error)
    /// Sending the managed pasteboard to the device failed. SimPasteboardPlus does not report it.
    case failedToSend(Error)
    /// Automatic synchronization replaced the managed pasteboard with the device's; `generation` is its resulting
    /// change count. It completes no Get Pasteboard. SimPasteboardPlus reports `applied` instead.
    case appliedAutomatically(generation: Int)
    /// An automatic transfer in the given direction failed. It fails no requested transfer. SimPasteboardPlus does not
    /// report it.
    case automaticTransferFailed(PasteboardTransfer, Error)
    /// The device closed the connection. Later pushes and pulls on it do nothing.
    case lostConnection
    /// The connection started or stopped synchronizing automatically.
    case synchronizationChanged(Bool)
    /// Observing a pasteboard failed, which stopped automatic synchronization until it is turned on again. The
    /// connection still transfers on request. SimPasteboardPlus does not report it.
    case synchronizationFailed(Error)
}

/// A device's pasteboard connection. Releasing it closes the connection.
@MainActor
package protocol SimulatorPasteboard: AnyObject {
    /// SimPasteboardPlus `pull`: Edit ▸ Get Pasteboard.
    func pull() async throws
    /// SimPasteboardPlus `push`: Edit ▸ Send Pasteboard.
    func push() async throws
    /// Sends the managed pasteboard for automatic synchronization rather than for Send Pasteboard, so that its outcome
    /// completes no requested transfer.
    func pushAutomatically() async throws
    /// Enables bidirectional automatic synchronization without an immediate transfer.
    func setAutomaticSync(_ enabled: Bool) async throws
    /// Stops the connection's events.
    func disconnect()
}

extension SimulatorPasteboard {
    /// SimPasteboardPlus reports every push alike.
    package func pushAutomatically() async throws { try await push() }
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

/// Binds CoreSimDeviceIO's SimAudioHostRoutable port directly.
/// Xcode 27 removed SimulatorKit's SimDeviceAudioClient; this also supports custom device sets.
@MainActor
package struct SimulatorAudioInterface {
    /// `SimDevice.io`, the device's `SimDeviceIOClient`.
    package let deviceIO: NativeObjCMethod<AnyObject?>
    /// `SimDeviceIOClient.ioPorts`, remote proxies of the device's I/O ports.
    package let ioPorts: NativeObjCMethod<[AnyObject]>
    package let routable: Protocol

    package typealias DevicesChanged = @convention(block) (NSArray?) -> Void
    package typealias RouteChanged = @convention(block) (UInt64, NSString?) -> Void
    package typealias RouteCompletion = @convention(block) (NSError?) -> Void

    package init(runtime: ABIRuntime) async throws {
        guard let device = NSClassFromString("SimDevice"), let client = NSClassFromString("SimDeviceIOClient") else {
            throw SimulatorError.unavailable("CoreSimulator's device I/O classes are unavailable")
        }
        deviceIO = try await runtime.resolve(.objc(.method("io", as: (() -> AnyObject?).self)), on: device)
        ioPorts = try await runtime.resolve(.objc(.method("ioPorts", as: (() -> [AnyObject]).self)), on: client)
        // Port and device objects are remote proxies, bound on connection through their protocols.
        let protocols = [("SimAudioHostRoutable", SimulatorAudioPort.selectors),
                         ("SimAudioHostDevice", HostAudioDeviceMembers.selectors)]
        for (name, selectors) in protocols {
            guard let declared = objc_getProtocol(name) else {
                throw SimulatorError.unavailable("Required private protocol \(name) is unavailable")
            }
            for selector in selectors
            where unsafe protocol_getMethodDescription(declared, NSSelectorFromString(selector), true, true).name == nil {
                throw SimulatorError.unavailable("\(name) does not declare \(selector)")
            }
        }
        guard let routable = objc_getProtocol("SimAudioHostRoutable") else {
            throw SimulatorError.unavailable("Required private protocol SimAudioHostRoutable is unavailable")
        }
        self.routable = routable
        // Recent routes are saved with this value, so it must not change.
        let symbol = try await runtime.resolve(.c(.symbol("SimAudioHostUseSystemDefaultDeviceUID", kind: .data)))
        let systemDefault = unsafe symbol.withUnsafeAddress {
            unsafe $0.load(as: Unmanaged<NSString>?.self)?.takeUnretainedValue() as String?
        }
        guard systemDefault == AudioRouting.systemDefault else {
            throw SimulatorError.unavailable("SimAudioHostUseSystemDefaultDeviceUID is \(systemDefault ?? "nil")")
        }
    }

    /// Connects to the device's audio route port, which a booted device that
    /// has `SimFeatureRoutableAudio` provides.
    package func connect(to device: SimulatorDevice,
                 changed: @escaping @MainActor (AudioRouteChange) -> Void) async throws -> SimulatorAudioConnection {
        nonisolated(unsafe) let deviceIO = deviceIO, ioPorts = ioPorts, routable = routable, object = device.object
        let port = try await device.channel.read("connect the device's audio routes", lateCompletion: { result in
            if case .success(let port) = result { port.disconnect() }
        }) { () throws -> SimulatorAudioPort in
            guard let io = try unsafe deviceIO.unsafeInvoke(on: object) else {
                throw SimulatorError.unavailable("The device did not provide its I/O ports.")
            }
            var descriptor: NativeObjCMethod<AnyObject?>?
            for port in try unsafe ioPorts.unsafeInvoke(on: io) {
                // Every port is a proxy of one class.
                let method = try descriptor ?? ABIRuntime.shared.object(port)
                    .resolveAndWait(.objc(.method("descriptor", as: (() -> AnyObject?).self))).method
                descriptor = method
                if let found = try unsafe method.unsafeInvoke(on: port),
                   (found as? NSObjectProtocol)?.conforms(to: routable) == true {
                    return try SimulatorAudioPort(port: found, changed: changed)
                }
            }
            throw SimulatorError.unavailable("The device has no audio route port.")
        }
        return SimulatorAudioConnection(port: port, channel: device.channel)
    }
}

/// A device's audio routes: CoreSimDeviceIO's `SimAudioHostRoutable`.
@MainActor
package protocol SimulatorAudioRoutes: AnyObject {
    /// The Mac's audio devices and the guest's routes as the port reports them now.
    func state() async throws -> AudioRouteState
    /// Routes to a device UID or system default. Completion reports on the main actor. A throw means no completion
    /// follows, and that nothing was sent unless it says otherwise. CoreSimulator silently uses the default if the
    /// requested device is absent or lacks channels in this scope.
    func route(_ scope: AudioScope, to route: String, completion: @escaping @MainActor (Error?) -> Void) async throws
    /// Stops the change reports.
    func disconnect()
}

/// Observes host-device and guest-route changes, including those made by other processes.
@MainActor
package final class SimulatorAudioConnection: SimulatorAudioRoutes {
    package nonisolated static var portSelectors: [String] { SimulatorAudioPort.selectors }

    private let port: SimulatorAudioPort
    private let channel: SimulatorDeviceChannel
    private var isConnected = true

    fileprivate init(port: SimulatorAudioPort, channel: SimulatorDeviceChannel) {
        self.port = port
        self.channel = channel
    }

    isolated deinit { disconnect() }

    package func state() async throws -> AudioRouteState {
        try await channel.read("read the device's audio routes") { [port] in try port.state() }
    }

    package func route(_ scope: AudioScope, to route: String, completion: @escaping @MainActor (Error?) -> Void) async throws {
        try await channel.change("route the device's audio") { [port] in
            try port.route(scope, to: route, completion: completion)
        }
    }

    package func disconnect() {
        guard isConnected else { return }
        isConnected = false
        channel.cleanUp("stop the audio route reports") { [port] in port.disconnect() }
    }
}

/// The messages of a device's audio port, a proxy of its I/O server. Only the device's worker sends them, and it is the
/// only one to touch the members it caches.
private final class SimulatorAudioPort: @unchecked Sendable {
    static let selectors = [
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

    init(port: AnyObject, changed: @escaping @MainActor (AudioRouteChange) -> Void) throws {
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

    // Audio-port callbacks may ignore the completion queue. Bridge to the main actor explicitly.
    private static func devicesChanged(
        _ changed: @escaping @MainActor (AudioRouteChange) -> Void
    ) -> SimulatorAudioInterface.DevicesChanged {
        { _ in DispatchQueue.main.async { MainActor.assumeIsolated { changed(.availableDevices) } } }
    }

    private static func routeChanged(
        _ changed: @escaping @MainActor (AudioRouteChange) -> Void
    ) -> SimulatorAudioInterface.RouteChanged {
        { _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { changed(.selectedDevice) } } }
    }

    private static func routeCompleted(
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
        do { try unsafe unregister.unsafeInvoke(token) } catch {
            hostLog("Could not stop the audio route reports: \(error.localizedDescription)")
        }
    }
}

/// `SimAudioHostDevice`'s members. The Mac's devices are proxies of one
/// class, so the members are bound to the first and sent to each.
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

/// An uninitialized instance for an Objective-C initializer, which consumes it. A request makes it on the worker just
/// before that, so that no request that never runs has one to dispose of.
func allocate(_ type: AnyClass) -> AnyObject? {
    (type as? NSObject.Type)?.perform(NSSelectorFromString("alloc"))?.takeRetainedValue()
}

/// A hardware button, by its Indigo HID button number.
package enum DeviceButton: UInt32 {
    case home = 0, lock = 1, applePay = 500, softwareKeyboard = 1008, siri = 1010
    /// The watch side button.
    case side = 3000
    /// The Action button on devices with the `com.apple.hid.sting` feature.
    case actionSting = 3001
    /// The Action button on devices with the `com.apple.hid.staccato` feature.
    case actionStaccato = 3002

    /// The HID usage page and usage that CoreDevice's and DeviceKit's buttons send for this button.
    package var nativeUsage: (page: Int, usage: Int) {
        switch self {
        case .home: (0x0c, 0x40)
        case .lock: (0x0c, 0x30)
        // AL Digital Wallet.
        case .applePay: (0x0c, 0x1ba)
        // Eject, which DeviceKit's Toggle Software Keyboard sends.
        case .softwareKeyboard: (0x0c, 0xb8)
        // Voice Command.
        case .siri: (0x0c, 0xcf)
        case .side: (0x0c, 0x95)
        // User Defined 1 on Apple's vendor keyboard page, which DeviceKit's watchOS Action button sends.
        case .actionSting: (0xff01, 0x200)
        // A telephony-page usage, which DeviceKit's iOS Action button sends.
        case .actionStaccato: (0x0b, 0x2d)
        }
    }
}

/// A button of the Apple TV Remote, by the Indigo HID button number that
/// Simulator.app's remote sends.
package enum TVRemoteButton: UInt32 {
    case select = 0x190, menu = 0x191, tv = 0x192, playPause = 0x194
    case volumeUp = 0x195, volumeDown = 0x196, siri = 0x3f2
}

/// A touch on the Apple TV Remote's touch surface.
package struct TVRemoteTouch: Equatable {
    package enum Phase { case began, moved, ended }

    package var phase: Phase
    /// Where the touch is, from 0 to 1 from the surface's top-left corner.
    package var point: CGPoint
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
package enum WatchGesture: UInt32 {
    case doubleTap = 0, wristFlick = 1
}

/// An input Simulator.app sends as a down event and an up event.
package enum HIDInput: Hashable {
    case button(DeviceButton)
    /// A HID usage, such as a key on the consumer usage page.
    case usage(page: UInt32, usage: UInt32)
    /// A button of the Apple TV Remote.
    case tvRemote(TVRemoteButton)
    /// Held remote touch, built by `SimulatorDisplay.message(for:)` with its coordinates.
    case tvRemoteTouch

    package static let screenshot = HIDInput.usage(page: 0x0c, usage: 0x65)
    package static let volumeUp = HIDInput.usage(page: 0x0c, usage: 0xe9)
    package static let volumeDown = HIDInput.usage(page: 0x0c, usage: 0xea)

    /// The HID usage that a device's native button service takes for this input. Nil for the Apple TV Remote's inputs,
    /// which go to the remote's own targets.
    package var nativeButtonUsage: (page: Int, usage: Int)? {
        switch self {
        case .button(let button): button.nativeUsage
        case .usage(let page, let usage): (Int(page), Int(usage))
        case .tvRemote, .tvRemoteTouch: nil
        }
    }
}

package enum HIDState: UInt32 { case down = 1, up = 2 }

/// A Core Animation debug option of the guest, numbered as
/// `SimDevice setCADebugOption:enabled:` numbers it.
public enum CADebugOption: UInt32, CaseIterable, Sendable {
    case colorCopiedImages = 1
    case colorBlendedLayers = 2
    case colorMisalignedImages = 14
    case colorOffscreenRendered = 17

    /// The Debug menu's title for the option.
    package var title: String {
        switch self {
        case .colorCopiedImages: "Color Copied Images"
        case .colorBlendedLayers: "Color Blended Layers"
        case .colorMisalignedImages: "Color Misaligned Images"
        case .colorOffscreenRendered: "Color Off-screen Rendered"
        }
    }
}

/// `SimScreenUIOrientation`, the guest's interface orientation.
package enum SimScreenUIOrientation {
    /// The angle SimulatorKit's `SimScreenUIOrientation.toAngle()` gives a
    /// raw orientation: landscape 4 is shown at +90° and landscape 3 at -90°.
    package static func displayAngle(_ rawValue: UInt32) -> Double {
        switch rawValue {
        case 2: 180
        case 3: -90
        case 4: 90
        default: 0
        }
    }
}

/// Raw SimDigitizerInputView.TouchMode values used when trackpad force is unavailable.
package enum SimulatedTouchMode: Int {
    case shallow = 0, deep = 1
}

/// An Indigo HID message for one event. Sending transfers it to SimulatorKit;
/// a message that is not sent is freed.
package final class HIDMessage {
    package let input: HIDInput
    package let state: HIDState
    private var pointer: OpaquePointer?

    package init(input: HIDInput, state: HIDState, pointer: OpaquePointer) {
        self.input = input
        self.state = state
        self.pointer = pointer
    }

    package func take() -> OpaquePointer {
        guard let pointer else { preconditionFailure("A HID message is sent once.") }
        self.pointer = nil
        return pointer
    }

    deinit { free(UnsafeMutableRawPointer(pointer)) }
}

@MainActor
package protocol SimulatorDisplay: AnyObject {
    var isBooted: Bool { get }
    var captureDisplayID: UInt32? { get throws }
    func connectAppDisplay(uniqueID: String) async throws -> any SimulatorDisplay
    var view: NSView { get }
    /// The rendered device's rectangle, including visible chrome, in view coordinates.
    var deviceFrame: NSRect { get }
    /// The guest framebuffer rectangle in view coordinates; canvas resize handles stay outside it.
    var framebufferFrame: NSRect { get }
    var usesNativeCanvas: Bool { get }
    var nativePoseControls: NativeDevicePoseControls? { get }
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
    /// The embedded canvas magnification of a native composition presented outside the
    /// magnified document, which renders it after measuring; nil outside the canvas viewport.
    func setCanvasMagnification(_ magnification: CGFloat?)
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
    /// Controls SimulatorKit's own bezel resize cursors.
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
    /// Reads and flips the guest's appearance as one request.
    func toggleAppearance() async throws
    /// Posts a Darwin notification in the guest.
    func postNotification(_ name: String) async throws
    /// Sets a Darwin notification's state in the guest and posts it, as one request. Throws
    /// ``GuestNotificationNotPosted`` when the state changed and only the post failed.
    func sendNotificationState(_ name: String, to state: UInt64) async throws
    /// Reads a Darwin notification's state, then sets and posts what `change` makes of it, as one request. Throws
    /// ``GuestNotificationNotPosted`` when the state changed and only the post failed.
    func updateNotificationState(_ name: String, _ change: @escaping @Sendable (UInt64) -> UInt64) async throws
    /// Reads the guest's preferred text size, numbered as `SimulatorDevice` numbers it, and sets what `change` makes of
    /// it, if anything, as one request.
    func updateContentSizeCategory(_ change: @escaping @Sendable (Int) throws -> Int?) async throws
    /// Reads Increase Contrast's mode, 1 when it is off and 2 when it is on and 0 when unknown, and sets whether it is on
    /// as `change` decides, as one request.
    func updateIncreaseContrast(_ change: @escaping @Sendable (Int) throws -> Bool) async throws
    func triggerCloudSync() async throws
    /// The guest values that `notifications` and `debugOptions` name, read as one request. CoreSimulator drops the error
    /// of a debug option's read, so false can also mean that it failed.
    func guestState(notifications: [String], debugOptions: [CADebugOption]) async throws -> GuestStateReading
    /// The folder of the device's logs.
    func logDirectory() throws -> URL
    /// The file whose write makes the guest simulate a memory warning.
    func memoryWarningFile() throws -> URL
    /// Reads a Core Animation debug option, sets the opposite and reads it back, as one request.
    /// CoreSimulator drops the error of this change.
    func toggleCADebugOption(_ option: CADebugOption) async throws -> CADebugOptionChange
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
                           events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) async throws -> any SimulatorPasteboard
    /// Connects to the device's audio route port. `changed` runs on the main
    /// actor after each change the port reports, until it disconnects.
    func connectAudioRoutes(changed: @escaping @MainActor (AudioRouteChange) -> Void) async throws -> any SimulatorAudioRoutes
    /// Observes the existing or subsequently connected TVOut screen on the main actor.
    /// Each connection reports property changes through `changed` until disconnected.
    /// Releasing the token ends reports except queued callbacks; nil means no adapter.
    func registerForExternalScreen(
        changed: @escaping @MainActor () -> Void,
        found: @escaping @MainActor (Result<any SimulatorExternalScreen, any Error>) -> Void
    ) throws -> AnyObject?
    func setChromeVisible(_ visible: Bool)
    func setKeyboardEnabled(_ enabled: Bool)
    /// Gives the screen the Mac trackpads' scrolling and pinches through the device's native trackpad, when it has one,
    /// whatever the hardware keyboard's state. Taking them away ends the gestures in progress.
    func setTrackpadEnabled(_ enabled: Bool)
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
    func endResize()
    func disconnect()
    /// Disconnects, then removes the native input services the display owns once they have sent the input they
    /// accepted. Every removal is attempted and their failures are thrown together, unless the device has shut down;
    /// the input owners keep what they could not remove, which the next call removes again.
    func stop() async throws
}

extension SimulatorDisplay {
    package var deviceFrame: NSRect { view.bounds }
    package var framebufferFrame: NSRect { view.bounds }
    package var usesNativeCanvas: Bool { false }
    package var nativePoseControls: NativeDevicePoseControls? { nil }
    package func setCanvasMagnification(_ magnification: CGFloat?) {}
    package var captureDisplayID: UInt32? { nil }
    package func connectAppDisplay(uniqueID: String) async throws -> any SimulatorDisplay {
        throw SimulatorError.unavailable("This display cannot connect to the app resizing screen.")
    }
}

@MainActor
package final class SimulatorConnection: SimulatorDisplay {
    package let view: NSView
    /// `SimDisplayView.digitizerView`.
    private let digitizerView: NSView?
    /// The display's user-interface plugin, once found.
    private var plugin: SimulatorUserInterfacePlugin?
    private let runtime: SimulatorRuntime
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
    /// The device's native keyboard, which takes the Mac's keyboard instead of SimulatorKit's Indigo keyboard.
    /// The integrated screen's connection owns it; external and app-resizing displays share it.
    private let keyboard: NativeDeviceKeyboard?
    private let ownsKeyboard: Bool
    private var keyboardResponder: NativeKeyboardResponder?
    /// The device's native trackpad, which takes the Mac trackpads' scrolling and pinches over the integrated screen
    /// instead of SimulatorKit's digitizer. Its guest services have no display of their own, so this connection alone has
    /// and owns it; external and app-resizing displays keep SimulatorKit's input.
    private let trackpad: NativeDeviceTrackpad?
    private var trackpadInput: NativeTrackpadInput?
    /// The device's native touchscreen and buttons, which take the touches that SimulatorKit's digitizer interprets on the
    /// integrated screen and the device's buttons and HID usages, instead of SimulatorKit's Indigo messages. This
    /// connection owns them; external and app-resizing displays keep SimulatorKit's input. A native canvas has only the
    /// buttons here, since its touches go through DeviceKit's view.
    private let screenInput: NativeDeviceScreenInput?
    private var digitizerTouches: NativeDigitizerTouches?

    /// A `touchRoute` that the display's digitizer cannot take leaves the screen with SimulatorKit's keyboard and
    /// touches, without `keyboard` and `trackpad`: the guest drops SimulatorKit's touches and buttons once native input
    /// starts.
    package init(device: SimulatorDevice, screen: (identifier: UInt32, object: AnyObject), runtime: SimulatorRuntime,
         nativeCanvas: NativeDeviceCanvas? = nil, keyboard: NativeDeviceKeyboard? = nil, ownsKeyboard: Bool = true,
         trackpad: NativeDeviceTrackpad? = nil, touchRoute: NativeTouchRoute? = nil) async throws {
        self.nativeCanvas = nativeCanvas
        self.device = device
        self.runtime = runtime
        self.screen = screen.object
        self.ownsKeyboard = ownsKeyboard
        connectedDisplayID = screen.identifier
        let display = runtime.display
        buttonTarget = try unsafe display.buttonTarget.unsafeInvoke(on: screen.object)
        hidClient = try await runtime.input.connect(to: device)
        if let nativeCanvas {
            view = nativeCanvas.view
            view.frame.size = nativeCanvas.naturalSize
            digitizerView = nil
            chromeView = nil
            self.keyboard = keyboard
            self.trackpad = trackpad
            screenInput = nativeCanvas.buttons
            nativeCanvas.onSizeChange = { [weak self] in self?.onPropertiesChange?() }
            return
        }
        guard let view = try unsafe display.createDisplay.unsafeInvoke(
            on: display.factoryClass as AnyObject, device.object, screen.identifier)
        else {
            throw SimulatorError.unavailable("SimulatorKit returned no display")
        }
        self.view = view
        var keyboard = keyboard, trackpad = trackpad
        do {
            try runtime.validateLoadedImages()
            let digitizer = try unsafe display.digitizerView.unsafeInvoke(on: view)
            digitizerView = digitizer
            chromeView = try unsafe display.chromeView.unsafeInvoke(on: view)
            if let touchRoute {
                do {
                    digitizerTouches = try await NativeDigitizerTouches(digitizer: digitizer, interface: touchRoute.interface) {
                        [input = touchRoute.input] touch in
                        input.sendTouch(at: touch.point, secondPoint: touch.secondPoint, phase: touch.phase, edge: touch.edge)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    hostLog("\(device.name) keeps SimulatorKit's keyboard and touches, without native trackpad input: \(error.localizedDescription)")
                    keyboard = nil
                    trackpad = nil
                }
            }
            try Task.checkCancellation()
            if let trackpad {
                let framebuffer = try unsafe display.renderableView.unsafeInvoke(on: view)
                trackpadInput = NativeTrackpadInput(display: view, framebuffer: framebuffer, send: trackpad.handle,
                                                    endGestures: trackpad.endGestures)
            }
        } catch {
            if let digitizerTouches {
                do { try digitizerTouches.restore() } catch {
                    hostLog("Could not give the digitizer its own delegate back: \(error.localizedDescription)")
                }
            }
            try? unsafe display.disconnect.unsafeInvoke(on: view, NativeSwiftClosure {})
            throw error
        }
        self.keyboard = keyboard
        self.trackpad = trackpad
        screenInput = digitizerTouches == nil ? nil : touchRoute?.input
        let handler = try SimulatorDisplayInterface.ScreenEventHandler { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onPropertiesChange?() }
        }
        screenEvents = try unsafe display.registerScreenEvents.unsafeInvoke(
            on: screen.object, display.screenPropertyEvents, .main, handler)
        // SimulatorKit connects keyboard input on every display and sends each modifier
        // change to all of them; the window controller enables it only while the window is key.
        // A native keyboard replaces it, which keeps Indigo from reattaching its own keyboard.
        setSimulatorKitKeyboardEnabled(false)
        if let keyboard {
            keyboardResponder = NativeKeyboardResponder { [weak self] event in
                guard let self, !disconnected, keyboard.isEnabled(for: self) else { return false }
                keyboard.handle(event)
                return true
            }
        }
    }

    package func connectAppDisplay(uniqueID: String) async throws -> any SimulatorDisplay {
        // Device Hub waits up to 30 seconds for the same uniqueId in this device's
        // screen adapter. CoreDevice displayId and SimulatorKit screenID differ.
        for _ in 0..<120 {
            try Task.checkCancellation()
            guard isBooted else { throw SimulatorError.unavailable("The simulator disconnected while preparing app resizing.") }
            if let screen = try runtime.display.appScreen(uniqueID: uniqueID, of: device) {
                let connection = try await SimulatorConnection(device: device, screen: screen, runtime: runtime,
                                                         keyboard: keyboard, ownsKeyboard: false)
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

    package func userInterfacePlugin() throws -> SimulatorUserInterfacePlugin? {
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
                                        userInfo: [name + "DeviceUserInfoKey": device.object])
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
        try await device.guestState(notifications: notifications, debugOptions: debugOptions)
    }
    package func logDirectory() throws -> URL { try device.logDirectory() }
    package func memoryWarningFile() throws -> URL { try device.memoryWarningFile() }
    package func toggleCADebugOption(_ option: CADebugOption) async throws -> CADebugOptionChange {
        try await device.toggleCADebugOption(option)
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
    package func connectPasteboard(_ pasteboard: NSPasteboard,
                           events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) async throws -> any SimulatorPasteboard {
        try await runtime.pasteboard.connect(to: device, managing: pasteboard, events: events)
    }
    package func connectAudioRoutes(changed: @escaping @MainActor (AudioRouteChange) -> Void) async throws -> any SimulatorAudioRoutes {
        try await runtime.audio.connect(to: device, changed: changed)
    }
    package func registerForExternalScreen(
        changed: @escaping @MainActor () -> Void,
        found: @escaping @MainActor (Result<any SimulatorExternalScreen, any Error>) -> Void
    ) throws -> AnyObject? {
        try runtime.display.registerForExternalScreens(of: device) { [device, runtime, keyboard] screen in
            found(Result {
                try SimulatorExternalScreenConnection(device: device, screen: try screen.get(), runtime: runtime,
                                                      keyboard: keyboard, changed: changed)
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
        guard nativeCanvas == nil, !disconnected else { return }
        // SimulatorKit's digitizer passes the keys it does not handle to the native keyboard. A device UI plugin's
        // overlay takes the input instead, so SimulatorKit's keyboard remains with that display.
        if enabled, let keyboard, let keyboardResponder, let digitizerView, inputView === digitizerView {
            keyboardResponder.attach(after: digitizerView)
            keyboard.setEnabled(true, for: self)
        } else if !enabled, let keyboard, keyboard.isEnabled(for: self) {
            keyboard.setEnabled(false, for: self)
        } else {
            setSimulatorKitKeyboardEnabled(enabled)
        }
    }
    private func setSimulatorKitKeyboardEnabled(_ enabled: Bool) {
        guard nativeCanvas == nil, !disconnected, let keyboard = object_getIvar(view, runtime.display.keyboardDelegate) else { return }
        perform("enable keyboard input") {
            try unsafe runtime.display.setKeyboardEnabled.unsafeInvoke(on: keyboard as AnyObject, enabled)
        }
    }
    package func setTrackpadEnabled(_ enabled: Bool) {
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
        disconnected = true
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

/// The native route of an integrated screen's touches and buttons: the device's services, and the SimulatorKit members
/// that take the screen's digitizer touches for them.
package struct NativeTouchRoute {
    package let input: NativeDeviceScreenInput
    package let interface: SimulatorTouchInterface
}

/// Gives a SimulatorKit digitizer a delegate whose methods are this host's callbacks, until `restore()`. The delegate
/// sends the touches the digitizer interprets, after its Option two-finger, pinned-finger, and edge handling, and passes
/// the digitizer's other callbacks, such as its first-responder requests, to the delegate it replaces.
@MainActor
package final class NativeDigitizerTouches {
    private weak var digitizer: NSView?
    private let interface: SimulatorTouchInterface
    private let send: (NativeDigitizerTouch) -> Void
    /// The digitizer's own delegate, which `restore()` gives back.
    private let original: NativeSwiftValue?
    private let forwarding: NativeDigitizerForwarding?
    /// The digitizer keeps its delegate weakly, so this keeps the replacement for as long as the digitizer has it.
    private var replacement: NativeSwiftValue?

    package init(digitizer: NSView, interface: SimulatorTouchInterface, send: @escaping (NativeDigitizerTouch) -> Void) async throws {
        self.digitizer = digitizer
        self.interface = interface
        self.send = send
        original = try unsafe interface.delegate.unsafeInvoke(on: digitizer)
        if let original {
            forwarding = try await NativeDigitizerForwarding(delegate: original, interface: interface)
        } else {
            forwarding = nil
        }
        let replacement = try await makeDelegate()
        try Task.checkCancellation()
        // The setter consumes its value, so it takes a copy of the delegate that this owner keeps.
        try unsafe interface.setDelegate.unsafeInvoke(on: digitizer, replacement.copy())
        self.replacement = replacement
        // A screen whose digitizer did not keep the delegate would have no touches while its other input is native.
        guard try unsafe interface.delegate.unsafeInvoke(on: digitizer).map(Self.object) === Self.object(replacement) else {
            let failure = SimulatorError.unavailable("SimulatorKit's digitizer did not keep NeoSimulator's touch delegate.")
            do { try restore() } catch {
                throw SimulatorError.operation([failure.localizedDescription, error.localizedDescription].joined(separator: "\n"))
            }
            throw failure
        }
    }

    /// Gives the digitizer its own delegate back. After a failure, the digitizer and this owner keep the replacement.
    package func restore() throws {
        guard replacement != nil else { return }
        if let digitizer { try unsafe interface.setDelegate.unsafeInvoke(on: digitizer, original?.copy()) }
        replacement = nil
    }

    private func makeDelegate() async throws -> NativeSwiftValue {
        // SimDigitizerInputView, an NSView, calls its delegate on the main thread while it handles AppKit events, and
        // each callback reads its borrowed arguments before it returns, so the touches keep the events' order.
        try await ABIRuntime.shared.makeSwiftProtocolValue(SimulatorTouchInterface.delegateProtocol, methods: [
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:touchEvent:)") {
                [weak self] (_: NativeSwiftBorrowedValue, event: NativeSwiftBorrowedValue) in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.receive(event) }
            },
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:wantsMouseMovedEvents:)") {
                [weak self] (view: NativeSwiftBorrowedValue, wants: Bool) in
                nonisolated(unsafe) let view = view
                MainActor.assumeIsolated { self?.forward("mouse-moved") { try $0.wantsMouseMovedEvents(view, wants) } }
            },
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:wantsFirstResponder:)") {
                [weak self] (view: NativeSwiftBorrowedValue, wants: Bool) in
                nonisolated(unsafe) let view = view
                MainActor.assumeIsolated { self?.forward("first-responder") { try $0.wantsFirstResponder(view, wants) } }
            },
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:pressureEvent:)") {
                [weak self] (view: NativeSwiftBorrowedValue, event: NativeSwiftBorrowedValue) in
                nonisolated(unsafe) let view = view
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.forward("pressure") { try $0.pressureEvent(view, event) } }
            },
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:scrollEvent:)") {
                [weak self] (view: NativeSwiftBorrowedValue, event: NativeSwiftBorrowedValue) in
                nonisolated(unsafe) let view = view
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.forward("scroll") { try $0.scrollEvent(view, event) } }
            },
        ], valueABIs: interface.eventABIs)
    }

    private func receive(_ event: NativeSwiftBorrowedValue) {
        do { if let touch = try interface.touch(event) { send(touch) } } catch {
            hostLog("Could not read a touch of the screen: \(error.localizedDescription)")
        }
    }

    private func forward(_ callback: String, _ body: (NativeDigitizerForwarding) throws -> Void) {
        guard let forwarding else { return }
        do { try body(forwarding) } catch {
            hostLog("Could not pass the digitizer's \(callback) callback to its delegate: \(error.localizedDescription)")
        }
    }

    /// The object of a class-bound protocol existential, which identifies the delegate whatever its concrete type.
    private static func object(_ value: NativeSwiftValue) throws -> AnyObject {
        try value.withCopy { $0 as AnyObject }
    }
}

/// Calls a digitizer delegate's requirements other than its touch events, through the protocol's requirements, which
/// select the witnesses of the delegate's own conformance.
@MainActor
package final class NativeDigitizerForwarding {
    private let delegate: NativeSwiftValue
    private let mouseMoved: NativeSwiftMethod<(NativeSwiftBorrowedValue, Bool) -> Void>
    private let firstResponder: NativeSwiftMethod<(NativeSwiftBorrowedValue, Bool) -> Void>
    private let pressure: NativeSwiftMethod<(NativeSwiftBorrowedValue, NativeSwiftBorrowedValue) -> Void>
    private let scroll: NativeSwiftMethod<(NativeSwiftBorrowedValue, NativeSwiftBorrowedValue) -> Void>

    package init(delegate existential: NativeSwiftValue, interface: SimulatorTouchInterface) async throws {
        let delegate = try existential.copyUnderlyingValue()
        let name = SimulatorTouchInterface.delegateProtocol + ".simDigitizerInputView"
        mouseMoved = try await delegate.type.resolve(.swift(.method(name + "(_:wantsMouseMovedEvents:)",
            as: ((NativeSwiftBorrowedValue, Bool) -> Void).self)))
        firstResponder = try await delegate.type.resolve(.swift(.method(name + "(_:wantsFirstResponder:)",
            as: ((NativeSwiftBorrowedValue, Bool) -> Void).self)))
        pressure = try await delegate.type.resolve(.swift(.method(name + "(_:pressureEvent:)",
            as: ((NativeSwiftBorrowedValue, NativeSwiftBorrowedValue) -> Void).self, valueABIs: interface.eventABIs)))
        scroll = try await delegate.type.resolve(.swift(.method(name + "(_:scrollEvent:)",
            as: ((NativeSwiftBorrowedValue, NativeSwiftBorrowedValue) -> Void).self, valueABIs: interface.eventABIs)))
        self.delegate = delegate
    }

    package func wantsMouseMovedEvents(_ view: NativeSwiftBorrowedValue, _ wants: Bool) throws {
        try unsafe mouseMoved.unsafeInvoke(on: delegate, view, wants)
    }

    package func wantsFirstResponder(_ view: NativeSwiftBorrowedValue, _ wants: Bool) throws {
        try unsafe firstResponder.unsafeInvoke(on: delegate, view, wants)
    }

    package func pressureEvent(_ view: NativeSwiftBorrowedValue, _ event: NativeSwiftBorrowedValue) throws {
        try unsafe pressure.unsafeInvoke(on: delegate, view, event)
    }

    package func scrollEvent(_ view: NativeSwiftBorrowedValue, _ event: NativeSwiftBorrowedValue) throws {
        try unsafe scroll.unsafeInvoke(on: delegate, view, event)
    }
}

/// Follows a SimulatorKit display's digitizer in its responder chain. The digitizer passes key-downs and key-ups
/// it does not handle to its next responder, including those `DisplayKeyboardInput` forwards and those AppKit
/// delivers after menu key equivalents. `handle` takes them for the native keyboard; events it declines continue
/// along the chain, as they did before.
@MainActor
package final class NativeKeyboardResponder: NSResponder {
    private let handle: (NSEvent) -> Bool
    private weak var view: NSView?

    package init(handle: @escaping (NSEvent) -> Bool) {
        self.handle = handle
        super.init()
    }
    package required init?(coder: NSCoder) { nil }

    /// AppKit resets a view's next responder when the view moves to another superview, so this attaches again then.
    package func attach(after view: NSView) {
        guard view.nextResponder !== self else { return }
        detach()
        nextResponder = view.nextResponder
        view.nextResponder = self
        self.view = view
    }

    package func detach() {
        if let view, view.nextResponder === self { view.nextResponder = nextResponder }
        view = nil
    }

    package override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }
    package override func keyUp(with event: NSEvent) {
        if !handle(event) { super.keyUp(with: event) }
    }
}

/// Takes the Mac trackpads' scrolling and pinches that begin over a SimulatorKit display's framebuffer, before its
/// digitizer drops them, and the mouse movements over the framebuffer that place them, for the device's native trackpad.
/// Events that begin elsewhere, such as over the bezel or a bar above the canvas, and Option-scrolling, which pans the
/// canvas, continue as before.
@MainActor
package final class NativeTrackpadInput: NSResponder {
    private weak var display: NSView?
    private weak var framebuffer: NSView?
    private let send: @MainActor (NSEvent, CGAffineTransform) -> Void
    private let endGestures: @MainActor () -> Void
    private var monitor: Any?
    private var tracking: NSTrackingArea?
    /// Whether the scroll or the pinch in progress began over the framebuffer. AppKit delivers the rest of a gesture,
    /// including a scroll's momentum, where it began, so those events follow it wherever the pointer goes.
    private var takesScroll = false
    private var takesPinch = false

    /// While enabled, the device takes the gestures; disabling ends those in progress.
    package var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { start() } else { stop() }
        }
    }

    package init(display: NSView, framebuffer: NSView, send: @escaping @MainActor (NSEvent, CGAffineTransform) -> Void,
         endGestures: @escaping @MainActor () -> Void) {
        self.display = display
        self.framebuffer = framebuffer
        self.send = send
        self.endGestures = endGestures
        super.init()
    }
    package required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let tracking { framebuffer?.removeTrackingArea(tracking) }
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            self?.take(event) == true ? nil : event
        }
        guard let framebuffer else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        framebuffer.addTrackingArea(area)
        tracking = area
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let tracking { framebuffer?.removeTrackingArea(tracking) }
        tracking = nil
        takesScroll = false
        takesPinch = false
        endGestures()
    }

    /// Sends `event` to the device when it belongs to a gesture over the framebuffer, which AppKit then does not deliver.
    private func take(_ event: NSEvent) -> Bool {
        guard let framebuffer else { return false }
        switch event.type {
        case .scrollWheel:
            // A trackpad's scroll begins with one of these phases; each of a mouse wheel's phaseless events stands alone.
            if !event.phase.isDisjoint(with: [.mayBegin, .began]) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
                takesScroll = !event.modifierFlags.contains(.option) && isOverFramebuffer(event)
            }
            guard takesScroll else { return false }
        case .magnify:
            if event.phase.contains(.began) { takesPinch = isOverFramebuffer(event) }
            guard takesPinch else { return false }
            if !event.phase.isDisjoint(with: [.ended, .cancelled]) { takesPinch = false }
        default:
            return false
        }
        send(event, NativeDeviceTrackpad.coordinateTransform(fromWindowTo: framebuffer))
        return true
    }

    package override func mouseMoved(with event: NSEvent) {
        guard isEnabled, let framebuffer, isOverFramebuffer(event) else { return }
        send(event, NativeDeviceTrackpad.coordinateTransform(fromWindowTo: framebuffer))
    }

    /// Whether `event` is over the framebuffer where nothing above the display, such as a bar over the canvas, takes it.
    private func isOverFramebuffer(_ event: NSEvent) -> Bool {
        guard let display, let framebuffer, let window = display.window, event.window === window,
              window.contentView?.superview?.hitTest(event.locationInWindow)?.isDescendant(of: display) == true
        else { return false }
        return framebuffer.bounds.contains(framebuffer.convert(event.locationInWindow, from: nil))
    }
}
