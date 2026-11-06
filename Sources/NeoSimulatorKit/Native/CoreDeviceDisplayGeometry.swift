import ABIBridge
import AppKit
import Observation
import SwiftUI

/// Reads the same normalized display orientation used by DeviceKit's display and HID owners.
@MainActor
package final class CoreDeviceDisplayGeometry {
    package struct Bindings {
        package let abis: [NativeSwiftType: NativeType]
        package let readDeviceInfo: NativeSwiftMethod<() -> NativeSwiftValue>
        package let readInitialDisplayInfo: NativeSwiftMethod<() async throws -> NativeSwiftValue>
        package let readDisplayInfo: NativeSwiftMethod<() -> NativeSwiftValue?>
        package let displays: NativeSwiftMethod<() -> [NativeSwiftValue]>
        package let orientation: NativeSwiftMethod<() -> NativeSwiftValue?>
        package let primary: NativeSwiftMethod<() -> Bool>
        package let uniqueID: NativeSwiftMethod<() -> String?>
        package let identifier: NativeSwiftMethod<() -> UInt32>
        package let makeDisplay: NativeSwiftFunction<(NativeSwiftValue, NativeSwiftValue?) -> NativeSwiftValue>
        package let normalizedOrientation: NativeSwiftMethod<() -> Measurement<UnitAngle>>
        package let displaySize: NativeSwiftMethod<() -> NativeSwiftValue>
        package let pointSize: NativeSwiftMethod<() -> CGSize>

        package init(runtime: ABIRuntime) async throws {
            let device = try await runtime.resolve(.swift(.type("CoreDevice.RemoteDevice")))
            readDeviceInfo = try await device.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
            let info = try await runtime.resolve(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
            let displayInfo = try await runtime.resolve(.swift(.type("CoreDevice.DisplayInfo")))
            let display = try await runtime.resolve(.swift(.type("CoreDevice.Display")))
            let orientationInfo = try await runtime.resolve(.swift(.type("CoreDevice.OrientationInfo")))
            let normalized = try await runtime.resolve(.swift(.type("DeviceKit.DisplayInfo")))
            let size = try await runtime.resolve(.swift(.type("DeviceKit.DisplaySize")))
            let angle = try await runtime.resolve(.swift(.type("Foundation.Measurement", genericArguments: [.type(UnitAngle.self)])))
            // DeviceKit and CoreDevice's display structs and Foundation's Measurement are resilient values;
            // their exported getters and initializer use indirect storage across the framework boundary.
            // Metadata shows this for each receiver except DisplaySize, whose CGSize field alone can explain
            // its addressable-for-dependencies bit.
            let abis = try Dictionary(uniqueKeysWithValues: [displayInfo, display, orientationInfo, normalized, size, angle]
                .map { ($0, try NativeType.opaque(named: $0.name)) })
            self.abis = abis
            readInitialDisplayInfo = try await device.resolve(.swift(.getter("displayInfo",
                as: (() async throws -> NativeSwiftValue).self, valueABIs: abis)))
            readDisplayInfo = try await info.resolve(.swift(.getter("displayInfo", as: (() -> NativeSwiftValue?).self, valueABIs: abis)))
            displays = try await displayInfo.resolve(.swift(.getter("displays", as: (() -> [NativeSwiftValue]).self, valueABIs: abis)))
            orientation = try await displayInfo.resolve(.swift(.getter("orientation", as: (() -> NativeSwiftValue?).self, valueABIs: abis)))
            primary = try await display.resolve(.swift(.getter("primary", as: (() -> Bool).self, valueABIs: abis)))
            uniqueID = try await display.resolve(.swift(.getter("uniqueId", as: (() -> String?).self, valueABIs: abis)))
            identifier = try await display.resolve(.swift(.getter("displayId", as: (() -> UInt32).self, valueABIs: abis)))
            makeDisplay = try await normalized.resolve(.swift(.initializer("init(display:orientation:)",
                as: ((NativeSwiftValue, NativeSwiftValue?) -> NativeSwiftValue).self, valueABIs: abis)))
            normalizedOrientation = try await normalized.resolve(.swift(.getter("normalizedCurrentOrientation",
                as: (() -> Measurement<UnitAngle>).self, valueABIs: abis)))
            displaySize = try await normalized.resolve(.swift(.getter("displaySize", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
            pointSize = try await size.resolve(.swift(.getter("pointSize", as: (() -> CGSize).self,
                valueABIs: abis, receiverABI: abis[size])))
        }
    }

    private static var runtimeLoaded = false
    private let remote: CoreDeviceRemoteScreenDevice
    private let bindings: Bindings
    private let displayUniqueID: String?
    private var update: (@MainActor (Result<RemoteScreenFramebuffer.Display?, any Error>) -> Void)?
    private var generation = 0

    package static func loadRuntime() async throws {
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

    package init(remote: CoreDeviceRemoteScreenDevice, displayUniqueID: String? = nil) async throws {
        self.remote = remote
        self.displayUniqueID = displayUniqueID
        bindings = try await Bindings(runtime: remote.runtime)
    }

    package func start(update: @escaping @MainActor (Result<RemoteScreenFramebuffer.Display?, any Error>) -> Void) async throws {
        generation += 1
        let token = generation
        self.update = update
        let initial = try await unsafe bindings.readInitialDisplayInfo.unsafeInvoke(on: remote.object)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        try readAndObserve(generation: token, initial: project(initial))
    }

    package func stop() {
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

    /// Reads what the device frame needs from a display, beyond the geometry the screen observes.
    package struct FrameBindings {
        package let chromeIdentifier: NativeSwiftMethod<() -> String?>
        package let maskIdentifier: NativeSwiftMethod<() -> String?>
        package let pixelSize: NativeSwiftMethod<() -> CGSize>
        package let scale: NativeSwiftMethod<() -> CGFloat>

        package init(runtime: ABIRuntime, abis: [NativeSwiftType: NativeType]) async throws {
            let display = try await runtime.resolve(.swift(.type("CoreDevice.Display")))
            let size = try await runtime.resolve(.swift(.type("DeviceKit.DisplaySize")))
            chromeIdentifier = try await display.resolve(.swift(.getter("chromeIdentifier", as: (() -> String?).self, valueABIs: abis)))
            maskIdentifier = try await display.resolve(.swift(.getter("framebufferMaskIdentifier", as: (() -> String?).self,
                valueABIs: abis)))
            pixelSize = try await size.resolve(.swift(.getter("pixelSize", as: (() -> CGSize).self,
                valueABIs: abis, receiverABI: abis[size])))
            scale = try await size.resolve(.swift(.getter("uiScale", as: (() -> CGFloat).self,
                valueABIs: abis, receiverABI: abis[size])))
        }
    }

    /// Reads the primary display's size and DeviceKit chrome identity, without observing its orientation.
    package static func primaryDisplay(of remote: CoreDeviceRemoteScreenDevice) async throws -> RemoteDeviceDisplay? {
        try await loadRuntime()
        let bindings = try await Bindings(runtime: remote.runtime)
        let frame = try await FrameBindings(runtime: remote.runtime, abis: bindings.abis)
        let info = try await unsafe bindings.readInitialDisplayInfo.unsafeInvoke(on: remote.object)
        guard let display = try unsafe bindings.displays.unsafeInvoke(on: info).first(where: {
            try unsafe bindings.primary.unsafeInvoke(on: $0)
        }) else { return nil }
        // DeviceKit's initializer consumes the CoreDevice display, so its identifiers are read first.
        let chrome = try unsafe frame.chromeIdentifier.unsafeInvoke(on: display)
        let mask = try unsafe frame.maskIdentifier.unsafeInvoke(on: display)
        let size = try unsafe bindings.displaySize.unsafeInvoke(on: bindings.makeDisplay.unsafeInvoke(display, nil))
        let pixels = try unsafe frame.pixelSize.unsafeInvoke(on: size)
        let scale = try unsafe frame.scale.unsafeInvoke(on: size)
        guard pixels.width > 0, pixels.height > 0, scale > 0 else { return nil }
        return RemoteDeviceDisplay(pixelSize: pixels, scale: scale, chromeIdentifier: chrome, maskIdentifier: mask)
    }

    private func project(_ displayInfo: NativeSwiftValue) throws -> RemoteScreenFramebuffer.Display? {
        let candidates = try unsafe bindings.displays.unsafeInvoke(on: displayInfo)
        guard let display = try candidates.first(where: {
            if let displayUniqueID { return try unsafe bindings.uniqueID.unsafeInvoke(on: $0) == displayUniqueID }
            return try unsafe bindings.primary.unsafeInvoke(on: $0)
        }) else { return nil }
        // DeviceKit's initializer consumes the CoreDevice display, so its identifier is read first.
        let identifier = try unsafe bindings.identifier.unsafeInvoke(on: display)
        let value = try unsafe bindings.makeDisplay.unsafeInvoke(display, bindings.orientation.unsafeInvoke(on: displayInfo))
        let angle = try unsafe bindings.normalizedOrientation.unsafeInvoke(on: value).converted(to: .degrees).value
        let size = try unsafe bindings.pointSize.unsafeInvoke(on: bindings.displaySize.unsafeInvoke(on: value))
        guard size.width > 0, size.height > 0, angle.isFinite else { return nil }
        return RemoteScreenFramebuffer.Display(size: size, angle: angle, identifier: identifier)
    }
}

/// Owns DeviceKit's complete device composition, including the display providers and input view.
@MainActor
package final class NativeDeviceCanvas {
    package let view: NSView
    package let poseControls: NativeDevicePoseControls
    /// The guest's buttons; DeviceKit's view owns the touches.
    package let buttons: NativeDeviceScreenInput
    private let hosting: NativeCanvasHostingView
    private let presentation: NativeCanvasPresentation
    private let values: [NativeSwiftValue]
    private let readCaptureDisplayID: () throws -> UInt32
    package var naturalSize: CGSize { presentation.naturalSize }
    package var captureDisplayID: UInt32 { get throws { try readCaptureDisplayID() } }
    package var onSizeChange: (() -> Void)?

    package var inputView: NSView {
        func find(in view: NSView) -> NSView? {
            if NSStringFromClass(type(of: view)) == "CoreDevicePopDeviceKitExtension.RealityRendererHostView" { return view }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return find(in: hosting) ?? hosting
    }

    package struct Bindings {
        package let make: NativeSwiftFunction<(UUID) -> NativeSwiftValue>
        package let start: NativeSwiftMethod<(NativeSwiftValue) -> NativeSwiftValue>
        package let chrome: NativeSwiftMethod<(NativeSwiftValue) -> NativeSwiftValue>
        package let behavior: NativeSwiftValue
        package let visible: NativeSwiftValue
        package let hidden: NativeSwiftValue
        package let canvasPath: WritableKeyPath<EnvironmentValues, Bool>
        package let zoomPath: WritableKeyPath<EnvironmentValues, CGFloat>
        package let environmentValues: [NativeSwiftValue]

        package init(runtime: ABIRuntime) async throws {
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

    /// Requires what the view itself needs: DeviceKit and the simulator's CoreDevice record, which names the device to
    /// DeviceView whatever state CoreDevice reports for it. The controls around the view have their own readiness and
    /// report their own errors when they are used. `lookUp` returns a caller-owned send right to the guest's Mach service
    /// of a name, as the simulator's `SimDevice` looks it up.
    package static func connect(simulatorUDID: String,
                                lookUp: @escaping @MainActor (String) throws -> UInt32) async throws -> NativeDeviceCanvas {
        try await CoreDeviceDisplayGeometry.loadRuntime()
        guard let identifier = try await CoreDeviceRemoteScreenDevice.simulatorIdentifier(udid: simulatorUDID),
              let uuid = UUID(uuidString: identifier) else {
            throw CLIError.unavailable("native-device-canvas", "CoreDevice has no record of this simulator, so DeviceKit cannot show its screen.")
        }
        let bindings = try await Bindings(runtime: ABIRuntime.shared)
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
        let captureDisplay: () throws -> UInt32
        do { captureDisplay = try await captureDisplayReader(deviceIdentifier: identifier) }
        catch is CancellationError { throw CancellationError() }
        catch { captureDisplay = { throw error } }
        return NativeDeviceCanvas(root: AnyView(root), presentation: presentation,
            poseControls: NativeDevicePoseControls(deviceIdentifier: uuid),
            buttons: NativeDeviceScreenInput(input: GuestButtonInput { try await SimulatorGuestHID(lookUp: lookUp) }),
            captureDisplay: captureDisplay, values: [base, activation, shown, hidden] + bindings.environmentValues)
    }

    /// Reads the display when a capture starts: CoreDevice may report no displays until it finds the booted device.
    private static func captureDisplayReader(deviceIdentifier: String) async throws -> () throws -> UInt32 {
        let remote = try await CoreDeviceRemoteScreenDevice(identifier: deviceIdentifier)
        let runtime = remote.runtime
        let infoType = try await runtime.resolve(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
        let displayInfo = try await runtime.resolve(.swift(.type("CoreDevice.DisplayInfo")))
        let display = try await runtime.resolve(.swift(.type("CoreDevice.Display")))
        let abis = try Dictionary(uniqueKeysWithValues: [displayInfo, display]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        let deviceInfo = try await remote.type.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let current = try await infoType.resolve(.swift(.getter("displayInfo", as: (() -> NativeSwiftValue?).self, valueABIs: abis)))
        let displays = try await displayInfo.resolve(.swift(.getter("displays", as: (() -> [NativeSwiftValue]).self, valueABIs: abis)))
        let active = try await display.resolve(.swift(.getter("active", as: (() -> Bool?).self, valueABIs: abis)))
        let external = try await display.resolve(.swift(.getter("external", as: (() -> Bool).self, valueABIs: abis)))
        let identifier = try await display.resolve(.swift(.getter("displayId", as: (() -> UInt32).self, valueABIs: abis)))
        return {
            let info = try unsafe deviceInfo.unsafeInvoke(on: remote.object)
            guard let current = try unsafe current.unsafeInvoke(on: info) else {
                throw CLIError.unavailable("capture-display", "CoreDevice reports no display information for this simulator.")
            }
            for display in try unsafe displays.unsafeInvoke(on: current) {
                if try unsafe active.unsafeInvoke(on: display) == true,
                   try unsafe !external.unsafeInvoke(on: display) {
                    return try unsafe identifier.unsafeInvoke(on: display)
                }
            }
            throw CLIError.unavailable("capture-display", "The device has no active integrated display to capture.")
        }
    }

    private init(root: AnyView, presentation: NativeCanvasPresentation, poseControls: NativeDevicePoseControls,
                 buttons: NativeDeviceScreenInput, captureDisplay: @escaping () throws -> UInt32, values: [NativeSwiftValue]) {
        hosting = NativeCanvasHostingView(rootView: root)
        hosting.sizingOptions = []
        self.presentation = presentation
        self.poseControls = poseControls
        self.buttons = buttons
        readCaptureDisplayID = captureDisplay
        self.values = values
        view = hosting
        hosting.contentSize = { CGSize(width: presentation.naturalSize.width * presentation.zoom,
                                       height: presentation.naturalSize.height * presentation.zoom) }
        presentation.onSizeChange = { [weak self] in
            self?.hosting.invalidateIntrinsicContentSize()
            self?.onSizeChange?()
        }
    }

    package func setChromeVisible(_ visible: Bool) { presentation.showsChrome = visible }
    /// Renders the presenting canvas's magnification after the composition is measured, as
    /// DeviceKit's own canvas applies its scale effect. An AppKit-magnified ancestor would change
    /// how the composition's AppKit-backed content measures.
    ///
    /// With a magnification, the view's frame is the scaled composition and the composition scales
    /// from its top-leading corner. With `nil`, the composition is centered in the view at its own size.
    package func setMagnification(_ magnification: CGFloat?) {
        guard presentation.magnification != magnification else { return }
        presentation.magnification = magnification
    }
    package func setZoom(_ zoom: CGFloat) {
        presentation.zoom = zoom
        hosting.invalidateIntrinsicContentSize()
    }
    package func disconnect() {
        poseControls.disconnect()
        hosting.content = nil
        hosting.rootView = AnyView(EmptyView())
    }
}

@MainActor
package final class NativeCanvasHostingView: NSHostingView<AnyView> {
    package var content: AnyView?
    package var contentSize: (() -> CGSize)?
    package override var intrinsicContentSize: NSSize { contentSize?() ?? super.intrinsicContentSize }
    package required init(rootView: AnyView) { content = rootView; super.init(rootView: rootView) }
    package required init?(coder: NSCoder) { nil }
    package override func viewDidMoveToWindow() {
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
package final class NativeCanvasPresentation {
    package var showsChrome = true
    package var zoom: CGFloat = 1
    package var magnification: CGFloat?
    package var naturalSize = CGSize(width: 500, height: 700)
    @ObservationIgnored package var onSizeChange: (() -> Void)?
}

package struct NativeCanvasRoot: View {
    package let presentation: NativeCanvasPresentation
    package let shown: AnyView
    package let hidden: AnyView
    package let canvasPath: WritableKeyPath<EnvironmentValues, Bool>
    package let zoomPath: WritableKeyPath<EnvironmentValues, CGFloat>
    package var body: some View {
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
