import ABIBridge
import AppKit
import CoreImage
import IOSurface
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import NeoSimulatorNative

/// A screen buffer shared with Core Animation; retaining it does not freeze its pixels.
package struct DeviceThumbnailFrame: Equatable {
    package let surface: IOSurface
    package let rotation: CGFloat
    package let chrome: DeviceThumbnailChrome?
    private let seed: UInt32
    package var size: CGSize { CGSize(width: surface.width, height: surface.height) }

    package init(surface: IOSurface, rotation: CGFloat = 0, chrome: DeviceThumbnailChrome? = nil) {
        self.surface = surface
        self.rotation = rotation
        self.chrome = chrome
        seed = IOSurfaceGetSeed(surface)
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        IOSurfaceGetID(lhs.surface) == IOSurfaceGetID(rhs.surface) && lhs.seed == rhs.seed
            && lhs.rotation == rhs.rotation && lhs.chrome === rhs.chrome
    }

    /// Freezes a small copy when a thumbnail stops receiving frames. Never copies a full-resolution screenshot.
    package func snapshot() async throws -> CGImage {
        let surface = surface
        let rotation = rotation
        let chrome = chrome
        return try await performBlockingIO {
            var image = CIImage(ioSurface: surface)
            if let chrome {
                let scale = 96 / max(chrome.size.width, chrome.size.height)
                let width = Int(ceil(chrome.size.width * scale)), height = Int(ceil(chrome.size.height * scale))
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw SimulatorError.unavailable("Could not preserve the device thumbnail.")
                }
                let screenScale = min(96 / image.extent.width, 96 / image.extent.height)
                let reduced = image.transformed(by: CGAffineTransform(scaleX: screenScale, y: screenScale))
                guard let screen = ThumbnailImageContext.shared.createCGImage(reduced, from: reduced.extent) else {
                    throw SimulatorError.unavailable("Could not preserve the device thumbnail.")
                }
                context.scaleBy(x: scale, y: scale)
                context.draw(chrome.image, in: CGRect(origin: .zero, size: chrome.size))
                if let mask = chrome.mask { context.clip(to: chrome.displayRect, mask: mask) }
                else { context.addPath(CGPath(roundedRect: chrome.displayRect, cornerWidth: chrome.cornerRadius,
                                              cornerHeight: chrome.cornerRadius, transform: nil)); context.clip() }
                context.draw(screen, in: chrome.displayRect)
                guard let result = context.makeImage() else {
                    throw SimulatorError.unavailable("Could not preserve the device thumbnail.")
                }
                image = CIImage(cgImage: result)
            }
            image = image.transformed(by: CGAffineTransform(rotationAngle: rotation))
            let size = image.extent.size
            let scale = min(1, 96 / max(size.width, size.height))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let result = ThumbnailImageContext.shared.createCGImage(scaled, from: scaled.extent) else {
                throw SimulatorError.unavailable("Could not preserve the device thumbnail.")
            }
            return result
        }
    }
}

private enum ThumbnailImageContext {
    static let shared = CIContext(options: [.cacheIntermediates: false])
}

@MainActor
package protocol DeviceThumbnailSource: AnyObject {
    func stop()
}

/// Receives existing screen buffers without opening another live display or input service.
@MainActor
package final class SimulatorScreenThumbnail: DeviceThumbnailSource {
    private struct Screen {
        let object: AnyObject
        let registration: NativeSwiftValue
    }

    private let runtime: SimulatorPresentationRuntime
    private var lease: SimulatorDeviceLease?
    private let bindings: Bindings
    private var adapter: AnyObject?
    private var chromeRenderer: DeviceThumbnailChromeRenderer?
    private let screenCornerRadius: CGFloat
    private var adapterRegistration: AnyObject?
    private var screens: [UInt32: Screen] = [:]
    private var updates: Task<Void, Never>?
    private let stream: AsyncStream<UInt32?>
    private let continuation: AsyncStream<UInt32?>.Continuation
    private var onFrame: ((DeviceThumbnailFrame?) -> Void)?
    private var onFailure: ((any Error) -> Void)?

    /// Where SimulatorKit reports to the handlers, which only pass the reports on. A screen waits for this queue while
    /// it reports a frame or a disconnection, and on the main thread a `SimDisplayView` waits for that screen's queue.
    private static let reports = DispatchQueue(label: "dev.lynnswap.NeoSimulator.thumbnail-reports")

    package static func connect(device: SimulatorHostDevice, onFrame: @escaping (DeviceThumbnailFrame?) -> Void,
                                onFailure: @escaping (any Error) -> Void) async throws -> any DeviceThumbnailSource {
        let xcodeURL: URL
        if let owner = device.ownerXcodeURL ?? device.catalogXcodeURL { xcodeURL = owner }
        else { xcodeURL = try await CoreDeviceRuntime.uiXcodeURL() }
        let runtime = try await SimulatorPresentationRuntime.load(xcodeURL: xcodeURL)
        let set = try await SimulatorDeviceSet.load(xcodeURL: xcodeURL, path: device.deviceSetPath)
        guard let lease = try await set.leaseClient(withIdentifier: device.identifier) else {
            throw SimulatorError.unavailable("The simulator is no longer available.")
        }
        let client = lease.device
        try await runtime.display.screenAdapter.prepare(for: client.handle.object)
        let adapter = try await waitForAdapter(read: {
            try runtime.display.screenAdapter.adapter(of: client.handle.object)
        })
        let bindings = try await Bindings()
        let chromeRenderer: DeviceThumbnailChromeRenderer?
        if let identifier = client.chromeIdentifier {
            chromeRenderer = try await DeviceThumbnailChromeRenderer(identifier: identifier,
                maskURL: client.record.framebufferMaskURL, context: client.serviceContext)
        } else { chromeRenderer = nil }
        try Task.checkCancellation()
        let thumbnail = SimulatorScreenThumbnail(runtime: runtime, lease: lease, adapter: adapter, bindings: bindings,
                                                 chromeRenderer: chromeRenderer,
                                                 onFrame: onFrame, onFailure: onFailure)
        try await thumbnail.start()
        return thumbnail
    }

    /// CoreSimulator can publish Booted before its I/O adapter, just as for a full screen connection.
    package static func waitForAdapter(read: () throws -> AnyObject?,
                                      wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) async throws -> AnyObject {
        for _ in 0..<40 {
            try Task.checkCancellation()
            if let adapter = try read() { return adapter }
            try await wait()
        }
        throw SimulatorError.unavailable("The simulator's screen adapter is not ready.")
    }

    private init(runtime: SimulatorPresentationRuntime, lease: SimulatorDeviceLease, adapter: AnyObject, bindings: Bindings,
                 chromeRenderer: DeviceThumbnailChromeRenderer?,
                 onFrame: @escaping (DeviceThumbnailFrame?) -> Void, onFailure: @escaping (any Error) -> Void) {
        self.runtime = runtime
        self.lease = lease
        screenCornerRadius = lease.device.screenCornerRadius
        self.adapter = adapter
        self.bindings = bindings
        self.chromeRenderer = chromeRenderer
        self.onFrame = onFrame
        self.onFailure = onFailure
        let (stream, continuation) = AsyncStream<UInt32?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.stream = stream
        self.continuation = continuation
    }

    private func start() async throws {
        guard let adapter, let lease else { throw CancellationError() }
        let continuation = continuation
        let handler = try SimulatorDisplayInterface.AdapterEventHandler { _ in continuation.yield(nil) }
        adapterRegistration = try await runtime.display.registerEvents(
            of: adapter, queue: Self.reports, on: lease.device.screenChannel, handler: handler)
        try await refreshScreens()
        let stream = stream
        updates = Task(priority: .utility) { [weak self] in
            for await identifier in stream {
                guard !Task.isCancelled else { return }
                do {
                    // An adapter change can be coalesced with a later frame notification.
                    try await self?.refreshScreens()
                    try self?.publishFrame(preferred: identifier)
                    // Coalesce incoming frames instead of putting a task for each frame on the main actor.
                    try await Task.sleep(for: .milliseconds(200))
                } catch is CancellationError { return }
                catch { self?.onFailure?(error); self?.stop(); return }
            }
        }
        continuation.yield(nil)
    }

    isolated deinit { stop() }

    package func stop() {
        updates?.cancel()
        updates = nil
        continuation.finish()
        screens.removeAll()
        adapterRegistration = nil
        adapter = nil
        chromeRenderer = nil
        lease = nil
        onFrame = nil
        onFailure = nil
    }

    private func refreshScreens() async throws {
        guard let adapter, let channel = lease?.device.screenChannel else { return }
        let values = try unsafe runtime.display.adapterScreens.unsafeInvoke(on: adapter)
        screens = screens.filter { values[$0.key] != nil }
        for (identifier, value) in values where screens[identifier] == nil {
            let screen = try value.withCopy { $0 as AnyObject }
            let properties = try unsafe runtime.display.screenProperties.unsafeInvoke(on: screen)
            // Only the device's own panels, not app-resizing or external displays.
            guard try runtime.display.screenMessages.send("screenType", to: properties, as: UInt64.self) == 0 else { continue }
            let continuation = continuation
            let handler = try SimulatorDisplayInterface.ScreenEventHandler { _, _ in continuation.yield(identifier) }
            let registration = try await runtime.display.registerEvents(
                of: screen, types: bindings.events, queue: Self.reports, on: channel, handler: handler)
            // Stopping meanwhile ends what this registered.
            guard self.adapter != nil else { return }
            screens[identifier] = Screen(object: screen, registration: registration)
        }
    }

    private func publishFrame(preferred: UInt32?) throws {
        let ordered = screens.sorted { lhs, rhs in
            if lhs.key == preferred { return true }
            if rhs.key == preferred { return false }
            return lhs.key < rhs.key
        }
        for (_, screen) in ordered {
            let properties = try unsafe runtime.display.screenProperties.unsafeInvoke(on: screen.object)
            let messages = runtime.display.screenMessages
            guard try messages.send("powerState", to: properties, as: Int32.self) == 1,
                  let surface = try unsafe bindings.masked.unsafeInvoke(on: screen.object)
                    ?? bindings.unmasked.unsafeInvoke(on: screen.object) else { continue }
            let orientation = try messages.send("uiOrientation", to: properties, as: UInt32.self)
            let angle = SimScreenUIOrientation.displayAngle(orientation) * .pi / 180
            let scale = try unsafe runtime.display.screenScale.unsafeInvoke(on: screen.object)
            let chrome = try chromeRenderer?.chrome(
                displaySize: CGSize(width: CGFloat(surface.width) / scale, height: CGFloat(surface.height) / scale),
                cornerRadius: screenCornerRadius)
            onFrame?(DeviceThumbnailFrame(surface: surface, rotation: angle, chrome: chrome))
            return
        }
        onFrame?(nil)
    }

    private struct Bindings {
        let events: NativeSwiftValue
        let masked: NativeSwiftMethod<() -> IOSurface?>
        let unmasked: NativeSwiftMethod<() -> IOSurface?>

        init() async throws {
            let runtime = ABIRuntime.shared
            let screen = try await runtime.resolve(.swift(.type("SimulatorKit.SimDeviceScreen")))
            masked = try await screen.resolve(.swift(.getter("maskedSurface", as: (() -> IOSurface?).self)))
            unmasked = try await screen.resolve(.swift(.getter("unmaskedSurface", as: (() -> IOSurface?).self)))
            let types = try await runtime.resolve(.swift(.type("SimulatorKit.SimDeviceScreen.ScreenEventTypes")))
            events = try await unsafe types.resolve(.swift(.staticGetter("all", as: (() -> NativeSwiftValue).self,
                valueABIs: [types: try .opaque(named: types.name)]))).unsafeInvoke()
        }
    }
}
