import AppKit
import Darwin
import MachO
import ObjectiveC

@MainActor
final class SimulatorRuntime {
    let xcodeURL: URL
    let serviceClass: AnyClass
    let screenClass: AnyClass
    let factoryClass: AnyClass
    let hidClass: AnyClass
    let messageForButton: UnsafeMutableRawPointer
    let showChrome: UnsafeMutableRawPointer
    let chromeView: UnsafeMutableRawPointer
    let chromeState: UnsafeMutableRawPointer
    let digitizer: UnsafeMutableRawPointer
    let renderScale: UnsafeMutableRawPointer
    let rotation: UnsafeMutableRawPointer
    let disconnect: UnsafeMutableRawPointer
    let beginResize: UnsafeMutableRawPointer
    let resize: UnsafeMutableRawPointer
    let endResize: UnsafeMutableRawPointer

    init(xcodeURL: URL) throws {
        self.xcodeURL = xcodeURL.resolvingSymlinksInPath()
        _ = try Self.load(URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"))
        let simulatorKit = try Self.load(self.xcodeURL.appendingPathComponent("Contents/SharedFrameworks/SimulatorKit.framework"))
        _ = try Self.load(self.xcodeURL.appendingPathComponent("Contents/Frameworks/IDEPlaygroundSimulator.framework"))

        func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
            dlerror()
            guard let pointer = dlsym(simulatorKit, name) else {
                throw HostError.unavailable("Required private symbol \(name) is unavailable")
            }
            return pointer
        }
        messageForButton = try symbol("IndigoHIDMessageForButton")
        showChrome = try symbol("$s12SimulatorKit14SimDisplayViewC16showDeviceChromeSbvsTj")
        chromeView = try symbol("$s12SimulatorKit14SimDisplayViewC06chromeE0AA0cd6ChromeE0CvgTj")
        chromeState = try symbol("$s12SimulatorKit20SimDisplayChromeViewC5stateAC5StateOvsTj")
        digitizer = try symbol("$s12SimulatorKit14SimDisplayViewC09digitizerE0AA0c14DigitizerInputE0CvgTj")
        renderScale = try symbol("$s12SimulatorKit14SimDisplayViewC11renderScale12CoreGraphics7CGFloatVvgTj")
        rotation = try symbol("$s12SimulatorKit14SimDisplayViewC14deviceRotation10Foundation11MeasurementVySo11NSUnitAngleCGvsTj")
        disconnect = try symbol("$s12SimulatorKit14SimDisplayViewC10disconnect10completionyyycSg_tFTj")
        beginResize = try symbol("$s12SimulatorKit14SimDisplayViewC11beginResizeyyFTj")
        resize = try symbol("$s12SimulatorKit14SimDisplayViewC8resizeTo4sizeySo6CGSizeV_tFTj")
        endResize = try symbol("$s12SimulatorKit14SimDisplayViewC9endResizeyyFTj")

        serviceClass = try Self.requireClass("SimServiceContext",
            classMethods: ["sharedServiceContextForDeveloperDir:error:"],
            methods: ["defaultDeviceSetWithError:"])
        _ = try Self.requireClass("SimDeviceSet", methods: [
            "subscribeToNotificationsWithError:", "availableDevices",
            "registerNotificationHandlerOnQueue:handler:", "unregisterNotificationHandler:error:",
        ])
        _ = try Self.requireClass("SimDevice", methods: [
            "state", "name", "UDID", "runtime", "currentUIInterfaceStyle",
            "setUIInterfaceStyle:error:", "postDarwinNotification:error:",
        ])
        _ = try Self.requireClass("SimRuntime", methods: ["name", "platformIdentifier"])
        screenClass = try Self.requireClass("SimulatorKit.SimDeviceScreen",
            methods: ["initWithDevice:screenID:", "screen", "isDefault", "isCarPlay"])
        factoryClass = try Self.requireClass("IDEPlaygroundSimulator.IDESimulatorPlaygroundUntil",
            classMethods: ["createSimDisplayViewWithDevice:simScreenID:"])
        hidClass = try Self.requireClass("SimulatorKit.SimDeviceLegacyHIDClient",
            methods: ["initWithDevice:error:", "sendWithMessage:freeWhenDone:completionQueue:completion:"])
        try validateLoadedImages()
    }

    private static func load(_ url: URL) throws -> UnsafeMutableRawPointer {
        guard let executable = Bundle(url: url)?.executableURL else {
            throw HostError.unavailable("Missing framework at \(url.path)")
        }
        guard let handle = dlopen(executable.path, RTLD_NOW | RTLD_LOCAL) else {
            let detail = dlerror().map { String(cString: $0) } ?? "Unknown loader error"
            throw HostError.unavailable("Could not load \(executable.path): \(detail)")
        }
        // Objective-C class registration outlives these handles. Loaded Apple
        // frameworks stay mapped for the lifetime of the host process.
        return handle
    }

    private static func requireClass(_ name: String, classMethods: [String] = [],
                                     methods: [String] = []) throws -> AnyClass {
        guard let type = NSClassFromString(name) else {
            throw HostError.unavailable("Required private class \(name) is unavailable")
        }
        for name in classMethods where class_getClassMethod(type, NSSelectorFromString(name)) == nil {
            throw HostError.unavailable("\(type) does not provide +\(name)")
        }
        for name in methods where class_getInstanceMethod(type, NSSelectorFromString(name)) == nil {
            throw HostError.unavailable("\(type) does not provide -\(name)")
        }
        return type
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

    func openDeviceSet() throws -> XSHDeviceSetHandle {
        try XSHDeviceSetHandle(serviceClass: serviceClass,
            developerDirectory: xcodeURL.appendingPathComponent("Contents/Developer").path)
    }
}

enum DeviceButton: UInt32 {
    case home = 0, lock = 1, softwareKeyboard = 0x3f0
}

@MainActor
protocol SimulatorDisplay: AnyObject {
    var isBooted: Bool { get }
    var view: NSView { get }
    var inputView: NSView { get }
    var naturalSize: NSSize { get }
    func press(_ button: DeviceButton) throws
    func shake() throws
    func toggleAppearance() throws
    func setChromeVisible(_ visible: Bool)
    func setActive(_ active: Bool)
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
    private let device: XSHDeviceHandle
    private var hidClient: AnyObject?
    private var disconnected = false

    init(device: XSHDeviceHandle, screenID: UInt32, runtime: SimulatorRuntime) throws {
        self.device = device
        self.runtime = runtime
        var error: NSError?
        guard let client = XSHCreateHIDClient(runtime.hidClass, device, &error) else {
            throw error ?? HostError.unavailable("Could not connect simulator input") as NSError
        }
        hidClient = client as AnyObject
        guard let view = XSHCreateDisplay(runtime.factoryClass, device, screenID, &error) else {
            throw error ?? HostError.unavailable("Could not connect simulator display") as NSError
        }
        self.view = view
        do {
            try runtime.validateLoadedImages()
            guard let input = XSHSwiftCallObjectGetter(runtime.digitizer, view) as? NSView else {
                throw HostError.unavailable("Simulator display has no input view")
            }
            inputView = input
            guard let chrome = XSHSwiftCallObjectGetter(runtime.chromeView, view) as? NSView else {
                throw HostError.unavailable("Simulator display has no device chrome view")
            }
            chromeView = chrome
        } catch {
            XSHSwiftDisconnect(runtime.disconnect, view)
            throw error
        }
        setChromeVisible(true)
    }

    var isBooted: Bool { !disconnected && device.state == 3 }

    var naturalSize: NSSize {
        let scale = XSHSwiftCallCGFloatGetter(runtime.renderScale, view)
        let size = view.intrinsicContentSize
        let actual = size.width > 0 && size.height > 0 ? size : view.frame.size
        return scale > 0 ? NSSize(width: actual.width / scale, height: actual.height / scale) : actual
    }

    func press(_ button: DeviceButton) throws {
        guard let hidClient else { throw HostError.operation("Simulator input is disconnected") }
        var error: NSError?
        if !XSHSendButton(hidClient, runtime.messageForButton, button.rawValue, &error) {
            throw error ?? HostError.operation("Simulator input failed") as NSError
        }
    }

    func shake() throws { try device.shake() }
    func toggleAppearance() throws { try device.toggleAppearance() }
    func setChromeVisible(_ visible: Bool) {
        XSHSwiftCallBoolMethod(runtime.showChrome, view, visible)
        view.invalidateIntrinsicContentSize()
    }
    func setActive(_ active: Bool) {
        guard !disconnected else { return }
        XSHSwiftSetChromeActive(runtime.chromeState, chromeView, active)
    }
    func setRotation(degrees: Double) {
        XSHSwiftSetAngleMeasurement(runtime.rotation, view, degrees, .degrees)
        view.invalidateIntrinsicContentSize()
    }
    func beginResize() { XSHSwiftCallVoidMethod(runtime.beginResize, view) }
    func resize(to size: NSSize) {
        XSHSwiftCallCGSizeMethod(runtime.resize, view, size)
        view.invalidateIntrinsicContentSize()
    }
    func endResize() { XSHSwiftCallVoidMethod(runtime.endResize, view) }
    func disconnect() {
        guard !disconnected else { return }
        disconnected = true
        XSHSwiftDisconnect(runtime.disconnect, view)
        hidClient = nil
    }
    isolated deinit { disconnect() }
}
