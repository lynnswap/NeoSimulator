import ABIBridge
import AppKit
import Observation
import SwiftUI

/// Reads the same normalized display orientation used by DeviceKit's display and HID owners.
@MainActor
final class CoreDeviceDisplayGeometry {
    struct Bindings {
        let readDeviceInfo: NativeSwiftMethod<() -> NativeSwiftValue>
        let readInitialDisplayInfo: NativeSwiftMethod<() async throws -> NativeSwiftValue>
        let readDisplayInfo: NativeSwiftMethod<() -> NativeSwiftValue?>
        let displays: NativeSwiftMethod<() -> [NativeSwiftValue]>
        let orientation: NativeSwiftMethod<() -> NativeSwiftValue?>
        let primary: NativeSwiftMethod<() -> Bool>
        let uniqueID: NativeSwiftMethod<() -> String?>
        let identifier: NativeSwiftMethod<() -> UInt32>
        let makeDisplay: NativeSwiftFunction<(NativeSwiftValue, NativeSwiftValue?) -> NativeSwiftValue>
        let normalizedOrientation: NativeSwiftMethod<() -> Measurement<UnitAngle>>
        let displaySize: NativeSwiftMethod<() -> NativeSwiftValue>
        let pointSize: NativeSwiftMethod<() -> CGSize>

        init(deviceType: NativeSwiftType, runtime: ABIRuntime) throws {
            readDeviceInfo = try deviceType.resolveAndWait(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
            let info = try runtime.resolveAndWait(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
            let displayInfo = try runtime.resolveAndWait(.swift(.type("CoreDevice.DisplayInfo")))
            let display = try runtime.resolveAndWait(.swift(.type("CoreDevice.Display")))
            let orientationInfo = try runtime.resolveAndWait(.swift(.type("CoreDevice.OrientationInfo")))
            let normalized = try runtime.resolveAndWait(.swift(.type("DeviceKit.DisplayInfo")))
            let size = try runtime.resolveAndWait(.swift(.type("DeviceKit.DisplaySize")))
            let angle = try runtime.resolveAndWait(.swift(.type("Foundation.Measurement", genericArguments: [.type(UnitAngle.self)])))
            // DeviceKit and CoreDevice's display structs and Foundation's Measurement are resilient values;
            // their exported getters and initializer use indirect storage across the framework boundary.
            // Metadata shows this for each receiver except DisplaySize, whose CGSize field alone can explain
            // its addressable-for-dependencies bit.
            let abis = try Dictionary(uniqueKeysWithValues: [displayInfo, display, orientationInfo, normalized, size, angle]
                .map { ($0, try NativeType.opaque(named: $0.name)) })
            readInitialDisplayInfo = try deviceType.resolveAndWait(.swift(.getter("displayInfo",
                as: (() async throws -> NativeSwiftValue).self, valueABIs: abis)))
            readDisplayInfo = try info.resolveAndWait(.swift(.getter("displayInfo", as: (() -> NativeSwiftValue?).self, valueABIs: abis)))
            displays = try displayInfo.resolveAndWait(.swift(.getter("displays", as: (() -> [NativeSwiftValue]).self, valueABIs: abis)))
            orientation = try displayInfo.resolveAndWait(.swift(.getter("orientation", as: (() -> NativeSwiftValue?).self, valueABIs: abis)))
            primary = try display.resolveAndWait(.swift(.getter("primary", as: (() -> Bool).self, valueABIs: abis)))
            uniqueID = try display.resolveAndWait(.swift(.getter("uniqueId", as: (() -> String?).self, valueABIs: abis)))
            identifier = try display.resolveAndWait(.swift(.getter("displayId", as: (() -> UInt32).self, valueABIs: abis)))
            makeDisplay = try normalized.resolveAndWait(.swift(.initializer("init(display:orientation:)",
                as: ((NativeSwiftValue, NativeSwiftValue?) -> NativeSwiftValue).self, valueABIs: abis)))
            normalizedOrientation = try normalized.resolveAndWait(.swift(.getter("normalizedCurrentOrientation",
                as: (() -> Measurement<UnitAngle>).self, valueABIs: abis)))
            displaySize = try normalized.resolveAndWait(.swift(.getter("displaySize", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
            pointSize = try size.resolveAndWait(.swift(.getter("pointSize", as: (() -> CGSize).self,
                valueABIs: abis, receiverABI: abis[size])))
        }
    }

    private static var runtimeLoaded = false
    private let remote: CoreDeviceRemoteScreenDevice
    private let bindings: Bindings
    private let displayUniqueID: String?
    private var update: (@MainActor (Result<RemoteScreenFramebuffer.Display?, any Error>) -> Void)?
    private var generation = 0

    static func loadRuntime() async throws {
        guard !runtimeLoaded else { return }
        let url = try await deviceKitURL()
        guard !runtimeLoaded else { return }
        try CoreDeviceRemoteScreenDevice.load(url.path)
        runtimeLoaded = true
    }

    @concurrent
    private static func deviceKitURL() async throws -> URL {
        let xcodeURL = try await CoreDeviceRuntime.uiXcodeURL()
        return xcodeURL.appendingPathComponent(ToolConstants.deviceKitPath)
            .appendingPathComponent("Versions/A/DeviceKit")
    }

    init(remote: CoreDeviceRemoteScreenDevice, displayUniqueID: String? = nil) throws {
        self.remote = remote
        self.displayUniqueID = displayUniqueID
        bindings = try Bindings(deviceType: remote.type, runtime: remote.runtime)
    }

    func start(update: @escaping @MainActor (Result<RemoteScreenFramebuffer.Display?, any Error>) -> Void) async throws {
        generation += 1
        let token = generation
        self.update = update
        let initial = try await unsafe bindings.readInitialDisplayInfo.unsafeInvoke(on: remote.object).copyUnderlyingValue()
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        try readAndObserve(generation: token, initial: project(initial))
    }

    func stop() {
        generation += 1
        update = nil
    }

    private func readAndObserve(generation token: Int, initial: RemoteScreenFramebuffer.Display? = nil) throws {
        guard generation == token, update != nil else { return }
        let result = withObservationTracking {
            Result { try read() }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                do { try self.readAndObserve(generation: token) }
                catch { self.update?(.failure(error)) }
            }
        }
        update?(.success(try result.get() ?? initial))
    }

    private func read() throws -> RemoteScreenFramebuffer.Display? {
        let info = try unsafe bindings.readDeviceInfo.unsafeInvoke(on: remote.object)
        guard let displayInfo = try unsafe bindings.readDisplayInfo.unsafeInvoke(on: info) else { return nil }
        return try project(displayInfo)
    }

    private func project(_ displayInfo: NativeSwiftValue) throws -> RemoteScreenFramebuffer.Display? {
        let candidates = try unsafe bindings.displays.unsafeInvoke(on: displayInfo)
        guard let display = try candidates.first(where: {
            if let displayUniqueID { return try unsafe bindings.uniqueID.unsafeInvoke(on: $0) == displayUniqueID }
            return try unsafe bindings.primary.unsafeInvoke(on: $0)
        }) else { return nil }
        let value = try unsafe bindings.makeDisplay.unsafeInvoke(display, bindings.orientation.unsafeInvoke(on: displayInfo))
        let angle = try unsafe bindings.normalizedOrientation.unsafeInvoke(on: value).converted(to: .degrees).value
        let size = try unsafe bindings.pointSize.unsafeInvoke(on: bindings.displaySize.unsafeInvoke(on: value))
        guard size.width > 0, size.height > 0, angle.isFinite else { return nil }
        return try unsafe RemoteScreenFramebuffer.Display(size: size, angle: angle, identifier: bindings.identifier.unsafeInvoke(on: display))
    }
}

/// Owns DeviceKit's complete device composition, including the display providers and input view.
@_spi(NeoSimulator)
@MainActor
public final class NativeDeviceCanvas {
    public let view: NSView
    public let poseControls: NativeDevicePoseControls
    private let hosting: NativeCanvasHostingView
    private let presentation: NativeCanvasPresentation
    private let values: [NativeSwiftValue]
    private let sendNativeButton: (Int, Int, RemoteDeviceButtonState) throws -> Void
    private let readCaptureDisplayID: () throws -> UInt32
    public var naturalSize: CGSize { presentation.naturalSize }
    public var captureDisplayID: UInt32 { get throws { try readCaptureDisplayID() } }
    public var onSizeChange: (() -> Void)?

    public var inputView: NSView {
        func find(in view: NSView) -> NSView? {
            if NSStringFromClass(type(of: view)) == "CoreDevicePopDeviceKitExtension.RealityRendererHostView" { return view }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return find(in: hosting) ?? hosting
    }

    struct Bindings {
        let make: NativeSwiftFunction<(UUID) -> NativeSwiftValue>
        let start: NativeSwiftMethod<(NativeSwiftValue) -> NativeSwiftValue>
        let chrome: NativeSwiftMethod<(NativeSwiftValue) -> NativeSwiftValue>
        let behavior: NativeSwiftValue
        let visible: NativeSwiftValue
        let hidden: NativeSwiftValue
        let canvasPath: WritableKeyPath<EnvironmentValues, Bool>
        let zoomPath: WritableKeyPath<EnvironmentValues, CGFloat>
        let environmentValues: [NativeSwiftValue]

        init(runtime: ABIRuntime) async throws {
            let type = try await runtime.resolve(.swift(.type("DeviceKit.DeviceView")))
            let make = try await type.resolve(.swift(.initializer("init(deviceIdentifier:)",
                as: ((UUID) -> NativeSwiftValue).self, valueABIs: [type: try .opaque(named: type.name)])))
            let behaviorType = try await runtime.resolve(.swift(.type("DeviceKit.DeviceView.AutoStartBehavior")))
            let start = try await type.resolve(.swift(.method("liveDeviceAutoStart(_:)",
                as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                valueABIs: [behaviorType: try .opaque(named: behaviorType.name), type: try .opaque(named: type.name)])))
            let visibilityType = try await runtime.resolve(.swift(.type("SwiftUI.Visibility")))
            let chrome = try await type.resolve(.swift(.method("chromeVisibility(_:)",
                as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                valueABIs: [visibilityType: try .opaque(named: visibilityType.name), type: try .opaque(named: type.name)])))
            let environment = try await runtime.resolve(.swift(.type("SwiftUI.EnvironmentValues")))
            let bool = try await runtime.resolve(.swift(.type("Swift.Bool")))
            let canvasKey = try await environment.resolve(.swift(.writableKeyPath(
                "(extension in DeviceKit):SwiftUI.EnvironmentValues.isInDeviceCanvas", valueType: bool)))
            let scalar = try await runtime.resolve(.swift(.type("CoreGraphics.CGFloat")))
            let zoomKey = try await environment.resolve(.swift(.writableKeyPath(
                "(extension in DeviceKit):SwiftUI.EnvironmentValues.deviceCanvasZoom", valueType: scalar)))
            guard let canvasPath = try canvasKey.withCopy({ $0 as? WritableKeyPath<EnvironmentValues, Bool> }),
                  let zoomPath = try zoomKey.withCopy({ $0 as? WritableKeyPath<EnvironmentValues, CGFloat> }) else {
                throw CLIError.unavailable("native-device-environment", "DeviceKit's canvas environment is unavailable.")
            }
            self.make = make
            self.start = start
            self.chrome = chrome
            behavior = try behaviorType.makeEnumCase(named: "yes")
            visible = try visibilityType.makeEnumCase(named: "visible")
            hidden = try visibilityType.makeEnumCase(named: "hidden")
            self.canvasPath = canvasPath
            self.zoomPath = zoomPath
            environmentValues = [canvasKey, zoomKey]
        }
    }

    public static func connect(simulatorUDID: String) async throws -> NativeDeviceCanvas {
        try await CoreDeviceDisplayGeometry.loadRuntime()
        guard let identifier = try await CoreDeviceRemoteScreenDevice.simulatorIdentifier(udid: simulatorUDID),
              let uuid = UUID(uuidString: identifier) else {
            throw CLIError.unavailable("native-device-canvas", "The simulator is not available in DeviceKit.")
        }
        let remote = try await CoreDeviceRemoteScreenDevice(identifier: identifier)
        let button = try await remote.implementation(capability: "ButtonHIDCapability",
            feature: CoreDeviceScreenInput.features[.button]!)
        let runtime = ABIRuntime.shared
        let buttonState = try await runtime.resolve(.swift(.type("CoreDevice.HIDButtonState")))
        let down = try buttonState.makeEnumCase(named: "down")
        let up = try buttonState.makeEnumCase(named: "up")
        let send = try await button.type.resolve(.swift(.method("CoreDevice.HIDButton.sendCustomButton(usagePage:usageCode:state:)",
            as: ((Int, Int, NativeSwiftValue) throws -> Void).self)))
        let bindings = try await Bindings(runtime: runtime)
        let base = try unsafe bindings.make.unsafeInvoke(uuid)
        let activation = try unsafe bindings.start.unsafeInvoke(on: base, bindings.behavior)
        let shown = try unsafe bindings.chrome.unsafeInvoke(on: base, bindings.visible)
        let hidden = try unsafe bindings.chrome.unsafeInvoke(on: base, bindings.hidden)
        func content(_ value: NativeSwiftValue) throws -> AnyView {
            try value.withCopy { raw in
                guard let content = raw as? any View else {
                    throw CLIError.unavailable("native-device-view", "DeviceKit returned a value that is not a SwiftUI view.")
                }
                return AnyView(content)
            }
        }
        func activated(_ content: AnyView) throws -> AnyView {
            try activation.withCopy { raw in
                guard let modified = raw as? any NativeCanvasModifier else {
                    throw CLIError.unavailable("native-device-activation", "DeviceKit returned an unsupported activation modifier.")
                }
                return modified.apply(to: content)
            }
        }
        try Task.checkCancellation()
        let presentation = NativeCanvasPresentation()
        let root = NativeCanvasRoot(presentation: presentation, shown: try activated(content(shown)),
            hidden: try activated(content(hidden)), canvasPath: bindings.canvasPath, zoomPath: bindings.zoomPath)
        let poses = try await NativeDevicePoseControls.connect(deviceIdentifier: uuid)
        let captureDisplay = try await captureDisplayReader(for: remote)
        return NativeDeviceCanvas(root: AnyView(root), presentation: presentation, poseControls: poses,
            captureDisplay: captureDisplay,
            values: [base, activation, shown, hidden] + bindings.environmentValues) { page, usage, state in
                try unsafe send.unsafeInvoke(on: button, page, usage, state == .down ? down : up)
            }
    }

    private static func captureDisplayReader(for remote: CoreDeviceRemoteScreenDevice) async throws -> () throws -> UInt32 {
        let runtime = remote.runtime
        let infoType = try await runtime.resolve(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
        let displayInfo = try await runtime.resolve(.swift(.type("CoreDevice.DisplayInfo")))
        let display = try await runtime.resolve(.swift(.type("CoreDevice.Display")))
        let abis = try Dictionary(uniqueKeysWithValues: [displayInfo, display]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        let initial = try await remote.type.resolve(.swift(.getter("displayInfo",
            as: (() async throws -> NativeSwiftValue).self, valueABIs: abis)))
        _ = try await unsafe initial.unsafeInvoke(on: remote.object)
        let deviceInfo = try await remote.type.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let current = try await infoType.resolve(.swift(.getter("displayInfo", as: (() -> NativeSwiftValue?).self, valueABIs: abis)))
        let displays = try await displayInfo.resolve(.swift(.getter("displays", as: (() -> [NativeSwiftValue]).self, valueABIs: abis)))
        let active = try await display.resolve(.swift(.getter("active", as: (() -> Bool?).self, valueABIs: abis)))
        let external = try await display.resolve(.swift(.getter("external", as: (() -> Bool).self, valueABIs: abis)))
        let identifier = try await display.resolve(.swift(.getter("displayId", as: (() -> UInt32).self, valueABIs: abis)))
        return {
            let info = try unsafe deviceInfo.unsafeInvoke(on: remote.object)
            if let current = try unsafe current.unsafeInvoke(on: info) {
                for display in try unsafe displays.unsafeInvoke(on: current) {
                    if try unsafe active.unsafeInvoke(on: display) == true,
                       try unsafe !external.unsafeInvoke(on: display) {
                        return try unsafe identifier.unsafeInvoke(on: display)
                    }
                }
            }
            throw CLIError.unavailable("capture-display", "The device has no active integrated display to capture.")
        }
    }

    private init(root: AnyView, presentation: NativeCanvasPresentation, poseControls: NativeDevicePoseControls,
                 captureDisplay: @escaping () throws -> UInt32, values: [NativeSwiftValue],
                 sendButton: @escaping (Int, Int, RemoteDeviceButtonState) throws -> Void) {
        hosting = NativeCanvasHostingView(rootView: root)
        hosting.sizingOptions = []
        self.presentation = presentation
        self.poseControls = poseControls
        readCaptureDisplayID = captureDisplay
        self.values = values
        sendNativeButton = sendButton
        view = hosting
        hosting.contentSize = { CGSize(width: presentation.naturalSize.width * presentation.zoom,
                                       height: presentation.naturalSize.height * presentation.zoom) }
        presentation.onSizeChange = { [weak self] in
            self?.hosting.invalidateIntrinsicContentSize()
            self?.onSizeChange?()
        }
    }

    public func setChromeVisible(_ visible: Bool) { presentation.showsChrome = visible }
    /// Renders the presenting canvas's magnification after the composition is measured, as
    /// DeviceKit's own canvas applies its scale effect. An AppKit-magnified ancestor would change
    /// how the composition's AppKit-backed content measures.
    ///
    /// With a magnification, the view's frame is the scaled composition and the composition scales
    /// from its top-leading corner. With `nil`, the composition is centered in the view at its own size.
    public func setMagnification(_ magnification: CGFloat?) {
        guard presentation.magnification != magnification else { return }
        presentation.magnification = magnification
    }
    public func setZoom(_ zoom: CGFloat) {
        presentation.zoom = zoom
        hosting.invalidateIntrinsicContentSize()
    }
    public func sendButton(usagePage: Int, usage: Int, state: RemoteDeviceButtonState) throws {
        try sendNativeButton(usagePage, usage, state)
    }
    public func disconnect() {
        poseControls.disconnect()
        hosting.content = nil
        hosting.rootView = AnyView(EmptyView())
    }
}

@MainActor
final class NativeCanvasHostingView: NSHostingView<AnyView> {
    var content: AnyView?
    var contentSize: (() -> CGSize)?
    override var intrinsicContentSize: NSSize { contentSize?() ?? super.intrinsicContentSize }
    required init(rootView: AnyView) { content = rootView; super.init(rootView: rootView) }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // DeviceKit's screen-layer projection belongs to the hosting window.
        // Recreate that graph while retaining the device/session and posture owner.
        if let content, let window { rootView = AnyView(content.id(window.windowNumber)) }
        else { rootView = AnyView(EmptyView()) }
    }
}

// DeviceKit returns SwiftUI's public ModifiedContent for these modifiers. Opening
// its generic conformance preserves the native value without assuming its layout.
@MainActor
private protocol NativeCanvasModifier {
    func apply(to view: AnyView) -> AnyView
}

extension ModifiedContent: NativeCanvasModifier where Modifier: ViewModifier {
    @MainActor fileprivate func apply(to view: AnyView) -> AnyView { AnyView(view.modifier(modifier)) }
}

@MainActor @Observable
final class NativeCanvasPresentation {
    var showsChrome = true
    var zoom: CGFloat = 1
    var magnification: CGFloat?
    var naturalSize = CGSize(width: 500, height: 700)
    @ObservationIgnored var onSizeChange: (() -> Void)?
}

struct NativeCanvasRoot: View {
    let presentation: NativeCanvasPresentation
    let shown: AnyView
    let hidden: AnyView
    let canvasPath: WritableKeyPath<EnvironmentValues, Bool>
    let zoomPath: WritableKeyPath<EnvironmentValues, CGFloat>
    var body: some View {
        // AppKit owns the host frame: the root takes exactly the proposed size, even when the measured
        // composition is larger. A magnified presentation keeps the composition at the host's origin,
        // so the host frame changing on every zoom and pan step does not move it within SwiftUI's
        // pixel grid, and the scale effect maps it onto the frame.
        let magnification = presentation.magnification
        (presentation.showsChrome ? shown : hidden)
            .environment(canvasPath, false)
            .environment(zoomPath, presentation.zoom)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard size.width > 0, size.height > 0, size != presentation.naturalSize else { return }
                presentation.naturalSize = size
                presentation.onSizeChange?()
            }
            .scaleEffect(magnification ?? 1, anchor: magnification == nil ? .center : .topLeading)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                   alignment: magnification == nil ? .center : .topLeading)
            .clipped()
    }
}
