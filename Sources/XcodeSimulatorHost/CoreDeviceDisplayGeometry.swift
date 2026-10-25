import ABIBridge
import AppKit
import Observation

/// Reads the same normalized display orientation used by DeviceKit's display and HID owners.
@MainActor
final class CoreDeviceDisplayGeometry {
    private static var runtimeLoaded = false
    private let remote: CoreDeviceRemoteScreenDevice
    private let readDeviceInfo: NativeSwiftMethod<() -> NativeSwiftValue>
    private let readInitialDisplayInfo: NativeSwiftMethod<() async throws -> NativeSwiftValue>
    private let readDisplayInfo: NativeSwiftMethod<() -> NativeSwiftValue?>
    private let displays: NativeSwiftMethod<() -> [NativeSwiftValue]>
    private let orientation: NativeSwiftMethod<() -> NativeSwiftValue?>
    private let primary: NativeSwiftMethod<() -> Bool>
    private let makeDisplay: NativeSwiftFunction<(NativeSwiftValue, NativeSwiftValue?) -> NativeSwiftValue>
    private let normalizedOrientation: NativeSwiftMethod<() -> Measurement<UnitAngle>>
    private let displaySize: NativeSwiftMethod<() -> NativeSwiftValue>
    private let pointSize: NativeSwiftMethod<() -> CGSize>
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
        let renderer = Bundle.main.bundleURL.appendingPathComponent("Contents/Applications/NeoSimulatorRenderer.app")
        let xcode = try SimulatorHostController.discoverXcodes(rendererApplicationURL: renderer)[0]
        return xcode.applicationURL.appendingPathComponent(ToolConstants.deviceKitPath)
            .appendingPathComponent("Versions/A/DeviceKit")
    }

    init(remote: CoreDeviceRemoteScreenDevice) throws {
        self.remote = remote
        let runtime = remote.runtime
        readDeviceInfo = try remote.type.resolveAndWait(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let info = try runtime.resolveAndWait(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
        let displayInfo = try runtime.resolveAndWait(.swift(.type("CoreDevice.DisplayInfo")))
        let display = try runtime.resolveAndWait(.swift(.type("CoreDevice.Display")))
        let orientationInfo = try runtime.resolveAndWait(.swift(.type("CoreDevice.OrientationInfo")))
        let normalized = try runtime.resolveAndWait(.swift(.type("DeviceKit.DisplayInfo")))
        let size = try runtime.resolveAndWait(.swift(.type("DeviceKit.DisplaySize")))
        // DeviceKit and CoreDevice's display structs are resilient values; their exported getters
        // and initializer use indirect storage across the framework boundary.
        let abis = try Dictionary(uniqueKeysWithValues: [displayInfo, display, orientationInfo, normalized, size]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        readInitialDisplayInfo = try remote.type.resolveAndWait(.swift(.getter("displayInfo",
            as: (() async throws -> NativeSwiftValue).self, valueABIs: abis)))
        readDisplayInfo = try info.resolveAndWait(.swift(.getter("displayInfo", as: (() -> NativeSwiftValue?).self, valueABIs: abis)))
        displays = try displayInfo.resolveAndWait(.swift(.getter("displays", as: (() -> [NativeSwiftValue]).self, valueABIs: abis)))
        orientation = try displayInfo.resolveAndWait(.swift(.getter("orientation", as: (() -> NativeSwiftValue?).self, valueABIs: abis)))
        primary = try display.resolveAndWait(.swift(.getter("primary", as: (() -> Bool).self, valueABIs: abis)))
        makeDisplay = try normalized.resolveAndWait(.swift(.initializer("init(display:orientation:)",
            as: ((NativeSwiftValue, NativeSwiftValue?) -> NativeSwiftValue).self, valueABIs: abis)))
        normalizedOrientation = try normalized.resolveAndWait(.swift(.getter("normalizedCurrentOrientation",
            as: (() -> Measurement<UnitAngle>).self, valueABIs: abis)))
        displaySize = try normalized.resolveAndWait(.swift(.getter("displaySize", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        pointSize = try size.resolveAndWait(.swift(.getter("pointSize", as: (() -> CGSize).self, valueABIs: abis)))
    }

    func start(update: @escaping @MainActor (Result<RemoteScreenFramebuffer.Display?, any Error>) -> Void) async throws {
        generation += 1
        let token = generation
        self.update = update
        let initial = try await unsafe readInitialDisplayInfo.unsafeInvoke(on: remote.object).copyUnderlyingValue()
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
        let info = try unsafe readDeviceInfo.unsafeInvoke(on: remote.object)
        guard let displayInfo = try unsafe readDisplayInfo.unsafeInvoke(on: info) else { return nil }
        return try project(displayInfo)
    }

    private func project(_ displayInfo: NativeSwiftValue) throws -> RemoteScreenFramebuffer.Display? {
        let candidates = try unsafe displays.unsafeInvoke(on: displayInfo)
        guard let display = try candidates.first(where: { try unsafe primary.unsafeInvoke(on: $0) }) else { return nil }
        let value = try unsafe makeDisplay.unsafeInvoke(display, orientation.unsafeInvoke(on: displayInfo))
        let angle = try unsafe normalizedOrientation.unsafeInvoke(on: value).converted(to: .degrees).value
        let size = try unsafe pointSize.unsafeInvoke(on: displaySize.unsafeInvoke(on: value))
        guard size.width > 0, size.height > 0, angle.isFinite else { return nil }
        return RemoteScreenFramebuffer.Display(size: size, angle: angle)
    }
}
