import ABIBridge
import AppKit
import NeoSimulatorDeviceIO
import Observation
import SwiftUI

/// Reads the same normalized display orientation used by DeviceKit's display and HID owners.
@MainActor
package final class CoreDeviceDisplayGeometry {
    package struct Bindings {
        let abis: [NativeSwiftType: NativeType]
        let readDeviceInfo: NativeSwiftMethod<() -> NativeSwiftValue>
        let readInitialDisplayInfo: NativeSwiftMethod<() async throws -> NativeSwiftValue>
        let readDisplayInfo: NativeSwiftMethod<() -> NativeSwiftValue?>
        let displays: NativeSwiftMethod<() -> [NativeSwiftValue]>
        let orientation: NativeSwiftMethod<() -> NativeSwiftValue?>
        let primary: NativeSwiftMethod<() -> Bool>
        let active: NativeSwiftMethod<() -> Bool?>
        let external: NativeSwiftMethod<() -> Bool>
        let type: NativeSwiftMethod<() -> NativeSwiftValue>
        let uniqueID: NativeSwiftMethod<() -> String?>
        let identifier: NativeSwiftMethod<() -> UInt32>
        let makeDisplay: NativeSwiftFunction<(NativeSwiftValue, NativeSwiftValue?) -> NativeSwiftValue>
        let normalizedOrientation: NativeSwiftMethod<() -> Measurement<UnitAngle>>
        let displaySize: NativeSwiftMethod<() -> NativeSwiftValue>
        let pointSize: NativeSwiftMethod<() -> CGSize>
        let pixelSize: NativeSwiftMethod<() -> CGSize>

        package init(runtime: ABIRuntime) async throws {
            let device = try await runtime.resolve(.swift(.type("CoreDevice.RemoteDevice")))
            readDeviceInfo = try await device.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
            let info = try await runtime.resolve(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
            let displayInfo = try await runtime.resolve(.swift(.type("CoreDevice.DisplayInfo")))
            let display = try await runtime.resolve(.swift(.type("CoreDevice.Display")))
            let displayType = try await runtime.resolve(.swift(.type("CoreDevice.Display.DisplayType")))
            let orientationInfo = try await runtime.resolve(.swift(.type("CoreDevice.OrientationInfo")))
            let normalized = try await runtime.resolve(.swift(.type("DeviceKit.DisplayInfo")))
            let size = try await runtime.resolve(.swift(.type("DeviceKit.DisplaySize")))
            let angle = try await runtime.resolve(.swift(.type("Foundation.Measurement", genericArguments: [.type(UnitAngle.self)])))
            // DeviceKit and CoreDevice's display structs and Foundation's Measurement are resilient values;
            // their exported getters and initializer use indirect storage across the framework boundary.
            // Metadata shows this for each receiver except DisplaySize, whose CGSize field alone can explain
            // its addressable-for-dependencies bit.
            let abis = try Dictionary(
                uniqueKeysWithValues: [displayInfo, display, displayType, orientationInfo, normalized, size, angle]
                .map { ($0, try NativeType.opaque(named: $0.name)) })
            self.abis = abis
            readInitialDisplayInfo = try await device.resolve(.swift(.getter("displayInfo",
                as: (() async throws -> NativeSwiftValue).self, valueABIs: abis)))
            readDisplayInfo = try await info.resolve(.swift(.getter("displayInfo", as: (() -> NativeSwiftValue?).self, valueABIs: abis)))
            displays = try await displayInfo.resolve(.swift(.getter("displays", as: (() -> [NativeSwiftValue]).self, valueABIs: abis)))
            orientation = try await displayInfo.resolve(.swift(.getter("orientation", as: (() -> NativeSwiftValue?).self, valueABIs: abis)))
            primary = try await display.resolve(.swift(.getter("primary", as: (() -> Bool).self, valueABIs: abis)))
            active = try await display.resolve(.swift(.getter("active", as: (() -> Bool?).self, valueABIs: abis)))
            external = try await display.resolve(.swift(.getter("external", as: (() -> Bool).self, valueABIs: abis)))
            type = try await display.resolve(.swift(.getter("type", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
            uniqueID = try await display.resolve(.swift(.getter("uniqueId", as: (() -> String?).self, valueABIs: abis)))
            identifier = try await display.resolve(.swift(.getter("displayId", as: (() -> UInt32).self, valueABIs: abis)))
            makeDisplay = try await normalized.resolve(.swift(.initializer("init(display:orientation:)",
                as: ((NativeSwiftValue, NativeSwiftValue?) -> NativeSwiftValue).self, valueABIs: abis)))
            normalizedOrientation = try await normalized.resolve(.swift(.getter("normalizedCurrentOrientation",
                as: (() -> Measurement<UnitAngle>).self, valueABIs: abis)))
            displaySize = try await normalized.resolve(.swift(.getter("displaySize", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
            pointSize = try await size.resolve(.swift(.getter("pointSize", as: (() -> CGSize).self,
                valueABIs: abis, receiverABI: abis[size])))
            pixelSize = try await size.resolve(.swift(.getter("pixelSize", as: (() -> CGSize).self,
                valueABIs: abis, receiverABI: abis[size])))
        }

        /// The display that shows the device's screen, among those CoreDevice reports.
        func shownDisplay(among displays: [NativeSwiftValue]) throws -> NativeSwiftValue? {
            DisplayState.shownIndex(among: try states(of: displays)).map { displays[$0] }
        }

        /// What decides whether each of the displays that CoreDevice reports shows the device's screen.
        func states(of displays: [NativeSwiftValue]) throws -> [DisplayState] {
            try displays.map {
                DisplayState(
                    identifier: try unsafe identifier.unsafeInvoke(on: $0),
                    // CoreDevice's display type has no raw value; its case is its description.
                    isBuiltIn: try unsafe type.unsafeInvoke(on: $0).withCopy { "\($0)" == "integrated" },
                    isActive: try unsafe active.unsafeInvoke(on: $0),
                    isExternal: try unsafe external.unsafeInvoke(on: $0),
                    isPrimary: try unsafe primary.unsafeInvoke(on: $0))
            }
        }
    }

    /// What decides whether a display shows the device's screen.
    package struct DisplayState {
        package let identifier: UInt32
        /// Whether the display is one of the device's own panels.
        package let isBuiltIn: Bool
        package let isActive: Bool?
        package let isExternal: Bool
        package let isPrimary: Bool

        package init(identifier: UInt32, isBuiltIn: Bool, isActive: Bool?, isExternal: Bool, isPrimary: Bool) {
            self.identifier = identifier
            self.isBuiltIn = isBuiltIn
            self.isActive = isActive
            self.isExternal = isExternal
            self.isPrimary = isPrimary
        }

        /// The display that shows the device's screen: the built-in display that its video carries, while the
        /// video shows which one. Otherwise it is the active built-in display, or the primary display when
        /// none reports that it is active. A folding device keeps its cover display primary while its inner
        /// display is the active one, and its video changes display before the active one does.
        package static func shownIndex(among displays: [DisplayState], carrying video: UInt32? = nil) -> Int? {
            if let video, let index = displays.firstIndex(where: { $0.isBuiltIn && $0.identifier == video }) {
                return index
            }
            return displays.firstIndex { $0.isActive == true && !$0.isExternal } ?? displays.firstIndex(where: \.isPrimary)
        }
    }

    private static var runtimeLoaded = false
    private let remote: CoreDeviceRemoteScreenDevice
    private let bindings: Bindings
    private let frame: FrameBindings
    private let displayUniqueID: String?
    private var update: (@MainActor (Result<RemoteScreenFramebuffer.Display?, any Error>) -> Void)?
    private var generation = 0
    private var observation: Task<Void, Never>?
    /// The built-in display whose pixels the device's video carries, while the video shows which one. The
    /// screen shows this display, ahead of the one that the device reports as active.
    package var videoDisplay: UInt32? {
        didSet { if videoDisplay != oldValue { reportDisplay() } }
    }

    isolated deinit { observation?.cancel() }

    package static func loadRuntime() async throws {
        guard !runtimeLoaded else { return }
        let url = try await deviceKitURL()
        guard !runtimeLoaded else { return }
        try await CoreDeviceRemoteScreenDevice.load(url.path)
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
        (bindings, frame) = try await remote.runtime.prepare { runtime in
            let bindings = try await Bindings(runtime: runtime)
            return (bindings, try await FrameBindings(runtime: runtime, abis: bindings.abis))
        }
    }

    package func start(update: @escaping @MainActor (Result<RemoteScreenFramebuffer.Display?, any Error>) -> Void) async throws {
        generation += 1
        observation?.cancel()
        observation = nil
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
        videoDisplay = nil
        observation?.cancel()
        observation = nil
    }

    /// Reports the display again, for a change that no device-info change announces.
    private func reportDisplay() {
        guard let update else { return }
        do {
            let info = try unsafe bindings.readDeviceInfo.unsafeInvoke(on: remote.object)
            // Without display info the observer's last report stands, and it reports again when the info arrives.
            guard let displayInfo = try unsafe bindings.readDisplayInfo.unsafeInvoke(on: info) else { return }
            update(.success(try project(displayInfo)))
        } catch {
            update(.failure(error))
        }
    }

    private func readAndObserve(generation token: Int, initial: RemoteScreenFramebuffer.Display? = nil) throws {
        guard generation == token, update != nil else { return }
        var initial = initial
        update?(.success(try read(initial: &initial)))
        // RemoteDevice publishes deviceInfoChanges; its snapshot getters do not register Swift Observation reads.
        observation = Task { [weak self, remote, initial] in
            var initial = initial
            let failure: any Error
            do {
                try await remote.followInfoChanges { [weak self] in
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.update?(Result { try self.read(initial: &initial) })
                }
                failure = RemoteScreenError.unavailable(
                    "remote-display-observation", "The device's display observation ended.")
            } catch { failure = error }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.update?(.failure(failure))
        }
    }

    private func read(initial: inout RemoteScreenFramebuffer.Display?) throws -> RemoteScreenFramebuffer.Display? {
        let info = try unsafe bindings.readDeviceInfo.unsafeInvoke(on: remote.object)
        // The async display-info request can finish before the device-info snapshot includes it.
        guard let displayInfo = try unsafe bindings.readDisplayInfo.unsafeInvoke(on: info) else { return initial }
        initial = nil
        return try project(displayInfo)
    }

    /// Reads what the device frame needs from a display, beyond the geometry the screen observes.
    package struct FrameBindings {
        let chromeIdentifier: NativeSwiftMethod<() -> String?>
        let maskIdentifier: NativeSwiftMethod<() -> String?>
        let scale: NativeSwiftMethod<() -> CGFloat>

        package init(runtime: ABIRuntime, abis: [NativeSwiftType: NativeType]) async throws {
            let display = try await runtime.resolve(.swift(.type("CoreDevice.Display")))
            let size = try await runtime.resolve(.swift(.type("DeviceKit.DisplaySize")))
            chromeIdentifier = try await display.resolve(.swift(.getter("chromeIdentifier", as: (() -> String?).self, valueABIs: abis)))
            maskIdentifier = try await display.resolve(.swift(.getter("framebufferMaskIdentifier", as: (() -> String?).self,
                valueABIs: abis)))
            scale = try await size.resolve(.swift(.getter("uiScale", as: (() -> CGFloat).self,
                valueABIs: abis, receiverABI: abis[size])))
        }
    }

    /// Reads the size and DeviceKit chrome identity of the display that shows the device's screen, without
    /// observing its orientation.
    package static func primaryDisplay(of remote: CoreDeviceRemoteScreenDevice) async throws -> RemoteDeviceDisplay? {
        try await loadRuntime()
        let (bindings, frame) = try await remote.runtime.prepare { runtime in
            let bindings = try await Bindings(runtime: runtime)
            let frame = try await FrameBindings(runtime: runtime, abis: bindings.abis)
            return (bindings, frame)
        }
        let info = try await unsafe bindings.readInitialDisplayInfo.unsafeInvoke(on: remote.object)
        guard let display = try bindings.shownDisplay(among: unsafe bindings.displays.unsafeInvoke(on: info))
        else { return nil }
        // DeviceKit's initializer consumes the CoreDevice display, so its identifiers are read first.
        let chrome = try unsafe frame.chromeIdentifier.unsafeInvoke(on: display)
        let mask = try unsafe frame.maskIdentifier.unsafeInvoke(on: display)
        let size = try unsafe bindings.displaySize.unsafeInvoke(on: bindings.makeDisplay.unsafeInvoke(display, nil))
        let pixels = try unsafe bindings.pixelSize.unsafeInvoke(on: size)
        let scale = try unsafe frame.scale.unsafeInvoke(on: size)
        guard pixels.width > 0, pixels.height > 0, scale > 0 else { return nil }
        return RemoteDeviceDisplay(pixelSize: pixels, scale: scale, chromeIdentifier: chrome, maskIdentifier: mask)
    }

    private func project(_ displayInfo: NativeSwiftValue) throws -> RemoteScreenFramebuffer.Display? {
        let candidates = try unsafe bindings.displays.unsafeInvoke(on: displayInfo)
        var builtIn: [RemoteScreenBuiltInDisplay] = []
        let found: NativeSwiftValue?
        if let displayUniqueID {
            found = try candidates.first(where: { try unsafe bindings.uniqueID.unsafeInvoke(on: $0) == displayUniqueID })
        } else {
            let states = try bindings.states(of: candidates)
            found = DisplayState.shownIndex(among: states, carrying: videoDisplay).map { candidates[$0] }
            let panels = states.indices.filter { states[$0].isBuiltIn }
            if panels.count > 1 {
                builtIn = try panels.map {
                    // DeviceKit's initializer consumes a display, and the shown one is read below.
                    let size = try unsafe bindings.displaySize.unsafeInvoke(
                        on: bindings.makeDisplay.unsafeInvoke(candidates[$0].copy(), nil))
                    return RemoteScreenBuiltInDisplay(
                        identifier: states[$0].identifier, pixelSize: try unsafe bindings.pixelSize.unsafeInvoke(on: size))
                }
            }
        }
        guard let display = found else { return nil }
        // DeviceKit's initializer consumes the CoreDevice display, so its identifiers are read first.
        let identifier = try unsafe bindings.identifier.unsafeInvoke(on: display)
        let isPrimary = try unsafe bindings.primary.unsafeInvoke(on: display)
        let chrome = try unsafe frame.chromeIdentifier.unsafeInvoke(on: display)
        let mask = try unsafe frame.maskIdentifier.unsafeInvoke(on: display)
        let value = try unsafe bindings.makeDisplay.unsafeInvoke(display, bindings.orientation.unsafeInvoke(on: displayInfo))
        let angle = try unsafe bindings.normalizedOrientation.unsafeInvoke(on: value).converted(to: .degrees).value
        let displaySize = try unsafe bindings.displaySize.unsafeInvoke(on: value)
        let size = try unsafe bindings.pointSize.unsafeInvoke(on: displaySize)
        guard size.width > 0, size.height > 0, angle.isFinite else { return nil }
        let pixels = try unsafe bindings.pixelSize.unsafeInvoke(on: displaySize)
        let scale = try unsafe frame.scale.unsafeInvoke(on: displaySize)
        return RemoteScreenFramebuffer.Display(size: size, angle: angle, identifier: identifier, isPrimary: isPrimary,
            frame: pixels.width > 0 && pixels.height > 0 && scale > 0
                ? RemoteDeviceDisplay(pixelSize: pixels, scale: scale, chromeIdentifier: chrome, maskIdentifier: mask)
                : nil,
            builtIn: builtIn)
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
        hosting.inputView {
            NSStringFromClass(type(of: $0)) == "CoreDevicePopDeviceKitExtension.RealityRendererHostView"
        }
    }

    package struct Bindings {
        let make: NativeSwiftFunction<(UUID) -> NativeSwiftValue>
        let start: NativeSwiftMethod<(NativeSwiftValue) -> NativeSwiftValue>
        let chrome: NativeSwiftMethod<(NativeSwiftValue) -> NativeSwiftValue>
        let behavior: NativeSwiftValue
        let visible: NativeSwiftValue
        let hidden: NativeSwiftValue
        package let canvasPath: WritableKeyPath<EnvironmentValues, Bool>
        package let zoomPath: WritableKeyPath<EnvironmentValues, CGFloat>
        let environmentValues: [NativeSwiftValue]

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
                throw RemoteScreenError.unavailable("native-device-environment", "DeviceKit's canvas environment is unavailable.")
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

    /// Waits for the CoreDevice record that identifies this simulator to DeviceKit.
    /// Surrounding controls connect independently. `lookUp` returns a caller-owned Mach send right.
    package static func connect(record: CoreDeviceSimulatorRecord,
                                pointsPerInch: CGFloat?,
                                lookUp: @escaping @MainActor (String) async throws -> UInt32) async throws -> NativeDeviceCanvas {
        try await CoreDeviceRuntime.loadDeviceKit()
        let remote = try await record.record(limit: DeviceOperationLimit.coreDeviceRecord)
        return try await connect(remote: remote, pointsPerInch: pointsPerInch,
            buttons: NativeDeviceScreenInput(input: GuestButtonInput { try await SimulatorGuestHID(lookUp: lookUp) }))
    }

    /// Composes DeviceKit's view of a device that CoreDevice knows. DeviceKit must be loaded.
    /// - Parameter buttons: Sends the device's buttons; DeviceKit's view owns the touches.
    package static func connect(remote: CoreDeviceRemoteScreenDevice, pointsPerInch: CGFloat? = nil,
                                buttons: NativeDeviceScreenInput) async throws -> NativeDeviceCanvas {
        guard let uuid = UUID(uuidString: remote.identifier) else {
            throw RemoteScreenError.unavailable("native-device-canvas", "CoreDevice's record of this device has no device identifier for DeviceKit.")
        }
        let bindings = try await ABIRuntime.shared.prepare { try await Bindings(runtime: $0) }
        let base = try unsafe bindings.make.unsafeInvoke(uuid)
        let activation = try unsafe bindings.start.unsafeInvoke(on: base, bindings.behavior)
        let shown = try unsafe bindings.chrome.unsafeInvoke(on: base, bindings.visible)
        let hidden = try unsafe bindings.chrome.unsafeInvoke(on: base, bindings.hidden)
        func content(_ value: NativeSwiftValue) throws -> AnyView {
            try value.withCopy { raw in
                guard let content = raw as? any View else {
                    throw RemoteScreenError.unavailable("native-device-view", "DeviceKit returned a value that is not a SwiftUI view.")
                }
                return AnyView(content)
            }
        }
        func activated(_ content: AnyView) throws -> AnyView {
            try activation.withCopy { raw in
                guard let modified = raw as? any NativeCanvasModifier else {
                    throw RemoteScreenError.unavailable("native-device-activation", "DeviceKit returned an unsupported activation modifier.")
                }
                return modified.apply(to: content)
            }
        }
        try Task.checkCancellation()
        let presentation = NativeCanvasPresentation()
        let root = NativeCanvasRoot(presentation: presentation, shown: try activated(content(shown)),
            hidden: try activated(content(hidden)), canvasPath: bindings.canvasPath, zoomPath: bindings.zoomPath)
        let captureDisplay: () throws -> UInt32
        do { captureDisplay = try await captureDisplayReader(remote: remote) }
        catch is CancellationError { throw CancellationError() }
        catch { captureDisplay = { throw error } }
        return NativeDeviceCanvas(root: AnyView(root), presentation: presentation,
            pointsPerInch: pointsPerInch,
            frameMargin: { try await frameMargin(remote: remote) },
            poseControls: NativeDevicePoseControls(deviceIdentifier: uuid),
            buttons: buttons,
            captureDisplay: captureDisplay, values: [base, activation, shown, hidden] + bindings.environmentValues)
    }

    /// Reserve the installed artwork's bezel and physical buttons around each projected screen.
    /// Zero means no chrome is declared. Nil preserves the full canvas if declared artwork cannot be measured.
    private static func frameMargin(remote: CoreDeviceRemoteScreenDevice) async throws -> CGFloat? {
        let (bindings, frame) = try await remote.runtime.prepare { runtime in
            let bindings = try await CoreDeviceDisplayGeometry.Bindings(runtime: runtime)
            let frame = try await CoreDeviceDisplayGeometry.FrameBindings(runtime: runtime, abis: bindings.abis)
            return (bindings, frame)
        }
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        defer { continuation.finish() }
        var iterator = changes.makeAsyncIterator()
        var displays: [NativeSwiftValue] = []
        while displays.isEmpty {
            try Task.checkCancellation()
            let result = withObservationTracking {
                Result<[NativeSwiftValue], any Error> {
                    let info = try unsafe bindings.readDeviceInfo.unsafeInvoke(on: remote.object)
                    guard let info = try unsafe bindings.readDisplayInfo.unsafeInvoke(on: info) else { return [] }
                    return try unsafe bindings.displays.unsafeInvoke(on: info)
                }
            } onChange: { continuation.yield(()) }
            displays = try result.get()
            if displays.isEmpty {
                guard await iterator.next() != nil else { throw CancellationError() }
            }
        }
        var margin: CGFloat = 0
        for display in displays {
            let chromeIdentifier = try unsafe frame.chromeIdentifier.unsafeInvoke(on: display)
            guard chromeIdentifier != nil else { continue }
            let size = try unsafe bindings.displaySize.unsafeInvoke(on: bindings.makeDisplay.unsafeInvoke(display, nil))
            let descriptor = RemoteDeviceDisplay(pixelSize: try unsafe bindings.pixelSize.unsafeInvoke(on: size),
                scale: try unsafe frame.scale.unsafeInvoke(on: size), chromeIdentifier: chromeIdentifier, maskIdentifier: nil)
            guard let resources = try RemoteDeviceChromeResources(display: descriptor, productType: nil) else { return nil }
            let chrome = try await NativeDeviceChrome(resources: resources)
            let points = CGSize(width: descriptor.pixelSize.width / descriptor.scale,
                                height: descriptor.pixelSize.height / descriptor.scale)
            guard let layout = try chrome.layout(for: descriptor,
                fitting: CGSize(width: points.width * 2, height: points.height * 2)) else { return nil }
            let scale = layout.screen.width / points.width
            margin = max(margin, max(layout.screen.minX, layout.screen.minY,
                layout.size.width - layout.screen.maxX, layout.size.height - layout.screen.maxY) / scale)
        }
        return margin
    }

    /// Reads the display when a capture starts: CoreDevice may report no displays until it finds the booted device.
    private static func captureDisplayReader(remote: CoreDeviceRemoteScreenDevice) async throws -> () throws -> UInt32 {
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
                throw RemoteScreenError.unavailable("capture-display", "CoreDevice reports no display information for this simulator.")
            }
            for display in try unsafe displays.unsafeInvoke(on: current) {
                if try unsafe active.unsafeInvoke(on: display) == true,
                   try unsafe !external.unsafeInvoke(on: display) {
                    return try unsafe identifier.unsafeInvoke(on: display)
                }
            }
            throw RemoteScreenError.unavailable("capture-display", "The device has no active integrated display to capture.")
        }
    }

    private init(root: AnyView, presentation: NativeCanvasPresentation, pointsPerInch: CGFloat?,
                 frameMargin: @escaping @MainActor () async throws -> CGFloat?,
                 poseControls: NativeDevicePoseControls,
                 buttons: NativeDeviceScreenInput, captureDisplay: @escaping () throws -> UInt32, values: [NativeSwiftValue]) {
        hosting = NativeCanvasHostingView(rootView: root)
        hosting.sizingOptions = []
        self.presentation = presentation
        self.poseControls = poseControls
        self.buttons = buttons
        readCaptureDisplayID = captureDisplay
        self.values = values
        view = hosting
        hosting.projection = NativeCanvasProjection(hosting: hosting, presentation: presentation,
            pointsPerInch: pointsPerInch, frameMargin: frameMargin)
        hosting.contentSize = { CGSize(width: presentation.naturalSize.width * presentation.zoom,
                                       height: presentation.naturalSize.height * presentation.zoom) }
        presentation.onSizeChange = { [weak self] in
            self?.hosting.invalidateIntrinsicContentSize()
            self?.onSizeChange?()
        }
    }

    package func setChromeVisible(_ visible: Bool) {
        presentation.showsChrome = visible
        hosting.projection?.invalidate()
    }
    /// Scales the measured composition, keeping AppKit-backed layout unchanged.
    /// A magnified composition uses its top-leading origin and a scaled frame;
    /// with nil magnification, it is centered at its natural size.
    package func setMagnification(_ magnification: CGFloat?) {
        guard presentation.magnification != magnification else { return }
        presentation.magnification = magnification
    }
    package func setZoom(_ zoom: CGFloat) {
        presentation.zoom = zoom
        hosting.invalidateIntrinsicContentSize()
    }
    package func disconnect() {
        hosting.projection = nil
        poseControls.disconnect()
        hosting.content = nil
        hosting.rootView = AnyView(EmptyView())
    }
}

@MainActor
package final class NativeCanvasHostingView: NSHostingView<AnyView> {
    package var content: AnyView?
    package var contentSize: (() -> CGSize)?
    package var projection: NativeCanvasProjection?
    private weak var hostingWindow: NSWindow?
    private var screenObserver: (any NSObjectProtocol)?
    package override var intrinsicContentSize: NSSize { contentSize?() ?? super.intrinsicContentSize }
    package required init(rootView: AnyView) { content = rootView; super.init(rootView: rootView) }
    package required init?(coder: NSCoder) { nil }
    /// Focus can be requested immediately after attachment, before SwiftUI creates the replacement input views.
    package func inputView(where matches: (NSView) -> Bool) -> NSView {
        layoutSubtreeIfNeeded()
        func find(in view: NSView) -> NSView? {
            if matches(view) { return view }
            for child in view.subviews {
                if let input = find(in: child) { return input }
            }
            return nil
        }
        return find(in: self) ?? self
    }
    package override func layout() {
        super.layout()
        projection?.invalidate()
    }
    isolated deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
    package override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        projection?.invalidate()
    }
    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        let projection = projection
        screenObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) {
                [weak projection] _ in projection?.invalidate()
            }
        }
        projection?.invalidate()
        // DeviceKit unregisters the Pop canvas's input surfaces when it leaves a window. A retained SwiftUI graph
        // does not register them on return, so every new attachment needs fresh representable views.
        guard let window else {
            hostingWindow = nil
            rootView = AnyView(EmptyView())
            return
        }
        guard let content, hostingWindow !== window else { return }
        hostingWindow = window
        rootView = AnyView(content.id(UUID()))
    }
}

/// DeviceKit's 3D canvas includes a large, fixed rendering surface. Its screen layers carry the
/// projected geometry, including perspective and posture, independently of the surrounding SwiftUI layout.
@MainActor
package final class NativeCanvasProjection {
    private weak var hosting: NativeCanvasHostingView?
    private let presentation: NativeCanvasPresentation
    private let pointsPerInch: CGFloat?
    private let readFrameMargin: @MainActor () async throws -> CGFloat?
    private var frameMargin: CGFloat?
    private var marginTask: Task<Void, Never>?
    private var layers: [CALayer] = []
    private var observations: [NSKeyValueObservation] = []

    package init(hosting: NativeCanvasHostingView, presentation: NativeCanvasPresentation,
                 pointsPerInch: CGFloat?, frameMargin: @escaping @MainActor () async throws -> CGFloat?) {
        self.hosting = hosting
        self.presentation = presentation
        self.pointsPerInch = pointsPerInch.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        readFrameMargin = frameMargin
    }

    isolated deinit { marginTask?.cancel() }

    package func update() {
        guard let hosting else { return }
        func screenLayers(in view: NSView) -> [CALayer] {
            if NSStringFromClass(type(of: view)).hasPrefix("_TtGC31CoreDevicePopDeviceKitExtension19ScreenLayerHostView") {
                return view.subviews.compactMap(\.layer)
            }
            return view.subviews.flatMap { screenLayers(in: $0) }
        }
        let current = screenLayers(in: hosting)
        if current != layers {
            layers = current
            observations = current.flatMap { layer in
                [layer.observe(\.transform) { @Sendable [weak self] _, _ in self?.invalidate() },
                 layer.observe(\.bounds) { @Sendable [weak self] _, _ in self?.invalidate() },
                 layer.observe(\.position) { @Sendable [weak self] _, _ in self?.invalidate() },
                 layer.observe(\.anchorPoint) { @Sendable [weak self] _, _ in self?.invalidate() },
                 layer.observe(\.isHidden) { @Sendable [weak self] _, _ in self?.invalidate() }]
            }
            let parents = Set(current.compactMap(\.superlayer))
            observations += parents.map { parent in
                parent.observe(\.bounds) { @Sendable [weak self] _, _ in self?.invalidate() }
            }
            if frameMargin == nil { loadFrameMargin() }
        }
        // A rebuilding graph has no screen layers yet. Keep its last frame instead of briefly fitting the full
        // rendering surface; the new layers will supply their geometry when they arrive.
        guard !current.isEmpty, let screen = hosting.window?.screen else { return }
        // Keep the complete canvas while its bezel is unknown. Frameless displays need no artwork,
        // and point conversion is independent of either measurement.
        let controlMargin = Self.hoverControlMargin(in: hosting)
        let viewport = Self.viewport(for: current, frameMargin: frameMargin,
            controlMargin: controlMargin, showsChrome: presentation.showsChrome)
        let pointScale = pointsPerInch.map { $0 / Self.hostDensity(on: screen) } ?? 1
        if let previous = presentation.viewport, let viewport,
           abs(viewport.minX - previous.minX) <= 0.25, abs(viewport.minY - previous.minY) <= 0.25,
           abs(viewport.width - previous.width) <= 0.25, abs(viewport.height - previous.height) <= 0.25,
           pointScale == presentation.pointScale { return }
        if viewport == nil, presentation.viewport == nil, pointScale == presentation.pointScale { return }
        presentation.viewport = viewport
        presentation.pointScale = pointScale
        presentation.onSizeChange?()
    }

    nonisolated package func invalidate() {
        // A native frame updates several layers together. Read them after that update completes.
        Task { @MainActor [weak self] in self?.update() }
    }

    private func loadFrameMargin() {
        marginTask?.cancel()
        let read = readFrameMargin
        marginTask = Task { [weak self] in
            let margin = try? await read()
            guard !Task.isCancelled, let self else { return }
            frameMargin = margin
            update()
        }
    }

    /// Coordinates are relative to the rendering surface's center, independent of SwiftUI's layout timing.
    package static func viewport(for layers: [CALayer], frameMargin: CGFloat?,
                                 controlMargin: CGFloat = 0, showsChrome: Bool = true) -> CGRect? {
        guard let margin = showsChrome ? frameMargin : 0 else { return nil }
        var result = CGRect.null
        for layer in layers where !layer.isHidden {
            guard let parent = layer.superlayer else { continue }
            let projected = layer.convert(layer.bounds.insetBy(dx: -margin, dy: -margin), to: parent)
                .offsetBy(dx: -parent.bounds.midX, dy: -parent.bounds.midY)
            guard !projected.isEmpty, projected.origin.x.isFinite, projected.origin.y.isFinite,
                  projected.width.isFinite, projected.height.isFinite else { continue }
            result = result.union(projected)
        }
        guard !result.isNull else { return nil }
        let clearance = showsChrome ? controlMargin : 0
        return result.insetBy(dx: -clearance, dy: -clearance)
    }

    private static func hoverControlMargin(in view: NSView) -> CGFloat {
        if NSStringFromClass(type(of: view)) == "CoreDevicePopDeviceKitExtension.RealityRendererHostView" {
            return hoverControlMargin(renderingHeight: view.bounds.height)
        }
        return view.subviews.map { hoverControlMargin(in: $0) }.max() ?? 0
    }

    /// The pop renderer sizes its icons against the full rendering surface, not the cropped screens.
    /// Reserve its outward gap, reveal travel, occlusion clearance and hit radius even while hidden.
    /// Reading animated icon bounds would resize the canvas on hover and miss uninitialized icons.
    package static func hoverControlMargin(renderingHeight: CGFloat) -> CGFloat {
        let diameter = renderingHeight * 0.013
        let radius = diameter / 2
        let gap = diameter * (0.4 + 0.15)
        let revealTravel = diameter * 0.4
        let occlusionClearance = radius * 2
        let hitRadius = radius * 1.8
        let revealHalo = diameter * 0.15
        return radius + gap + revealTravel + occlusionClearance + hitRadius + revealHalo
    }

    private static func hostDensity(on screen: NSScreen?) -> CGFloat {
        // Match DeviceKit's physical-size projection, including its fallback for virtual displays.
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let mode = CGDisplayCopyDisplayMode(number.uint32Value) else { return 127 }
        let density = CGFloat(mode.width) / (CGDisplayScreenSize(number.uint32Value).width / 25.4)
        return density.isFinite && (50...600).contains(density) ? density : 127
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
    package var compositionSize = CGSize(width: 500, height: 700)
    package var viewport: CGRect?
    package var pointScale: CGFloat = 1
    package var naturalSize: CGSize {
        let size = viewport?.size ?? compositionSize
        return CGSize(width: size.width * pointScale, height: size.height * pointScale)
    }
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
        let viewport = presentation.viewport ?? CGRect(x: -presentation.compositionSize.width / 2,
            y: -presentation.compositionSize.height / 2, width: presentation.compositionSize.width,
            height: presentation.compositionSize.height)
        let scale = presentation.pointScale * presentation.zoom
        (presentation.showsChrome ? shown : hidden)
            .environment(canvasPath, false)
            // DeviceKit's 1 means physical size. Convert once here, so the rest of the app uses device points.
            .environment(zoomPath, 1)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard size.width > 0, size.height > 0, size != presentation.compositionSize else { return }
                presentation.compositionSize = size
                presentation.onSizeChange?()
            }
            .offset(x: -viewport.midX, y: -viewport.midY)
            .frame(width: viewport.width, height: viewport.height)
            .scaleEffect(scale)
            .frame(width: viewport.width * scale, height: viewport.height * scale)
            .scaleEffect(magnification ?? 1, anchor: magnification == nil ? .center : .topLeading)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                   alignment: magnification == nil ? .center : .topLeading)
            .clipped()
    }
}
