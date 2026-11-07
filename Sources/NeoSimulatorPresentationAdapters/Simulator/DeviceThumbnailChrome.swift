import ABIBridge
import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit

/// A small, static rendering of SimulatorKit's model-specific bezel and hardware buttons.
package final class DeviceThumbnailChrome: Sendable {
    package let image: CGImage
    package let mask: CGImage?
    package let size: CGSize
    package let displayRect: CGRect
    package let cornerRadius: CGFloat

    init(image: CGImage, mask: CGImage?, size: CGSize, displayRect: CGRect, cornerRadius: CGFloat) {
        self.image = image
        self.mask = mask
        self.size = size
        self.displayRect = displayRect
        self.cornerRadius = cornerRadius
    }
}

@MainActor
final class DeviceThumbnailChromeRenderer {
    private let render: (CGSize, CGFloat) throws -> DeviceThumbnailChrome
    private var cached: DeviceThumbnailChrome?
    private var displaySize = CGSize.zero

    init(identifier: String, maskURL: URL?, context: AnyObject) async throws {
        let mask: CGImage?
        if let maskURL {
            guard let image = NSImage(contentsOf: maskURL) else {
                throw SimulatorError.unavailable("The simulator's screen mask is unavailable.")
            }
            var rect = CGRect(origin: .zero, size: image.size)
            let scale = 96 / max(rect.width, rect.height)
            rect.size = CGSize(width: rect.width * scale, height: rect.height * scale)
            mask = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        } else { mask = nil }
        let abi = ABIRuntime.shared
        let type = try await abi.resolve(.swift(.type("SimulatorKit.SimDisplayChromeView")))
        let make = try await type.resolve(.swift(.initializer("init(frame:)", as: ((CGRect) -> NSView).self)))
        let view = try unsafe make.unsafeInvoke(.zero)
        // Preserve the imported Objective-C class in the optional Swift setter's signature.
        func assignContext<Context>(_ contextType: Context.Type) async throws {
            let set = try await type.resolve(.swift(.setter("context", as: ((Context?) -> Void).self)))
            try unsafe set.unsafeInvoke(on: view, context as? Context)
        }
        try await _openExistential(Swift.type(of: context), do: assignContext)
        let setIdentifier = try await type.resolve(.swift(.setter("chromeIdentifier", as: ((String?) -> Void).self)))
        let setSize = try await type.resolve(.swift(.setter("displaySize", as: ((CGSize) -> Void).self)))
        let setScale = try await type.resolve(.swift(.setter("renderScale", as: ((CGFloat) -> Void).self)))
        let setSimple = try await type.resolve(.swift(.setter("preferSimpleChrome", as: ((Bool) -> Void).self)))
        let stateType = try await abi.resolve(.swift(.type("SimulatorKit.SimDisplayChromeView.State")))
        let setState = try await type.resolve(.swift(.setter("state", as: ((NativeSwiftValue) -> Void).self,
            valueABIs: [stateType: try .opaque(named: stateType.name)])))
        try unsafe setIdentifier.unsafeInvoke(on: view, identifier)
        try unsafe setSimple.unsafeInvoke(on: view, false)
        try unsafe setState.unsafeInvoke(on: view, stateType.makeEnumCase(named: "active"))
        let getChrome = try await type.resolve(.swift(.getter("chrome", as: (() -> NativeSwiftValue?).self)))
        let chromeType = try await abi.resolve(.swift(.type("SimulatorKit.SimDeviceChrome")))
        let chromeFrame = try await chromeType.resolve(.swift(.method("chromeFrame(displaySize:renderScale:)",
            as: ((CGSize, CGFloat) -> CGRect).self, receiverABI: .opaque(named: chromeType.name))))
        let screenFrame = try await chromeType.resolve(.swift(.method("framebufferFrame(displaySize:renderScale:)",
            as: ((CGSize, CGFloat) -> CGRect).self, receiverABI: .opaque(named: chromeType.name))))
        render = { size, radius in
            try unsafe setSize.unsafeInvoke(on: view, size)
            guard let chrome = try unsafe getChrome.unsafeInvoke(on: view) else {
                throw SimulatorError.unavailable("The simulator's device bezel is unavailable.")
            }
            let outer = try unsafe chromeFrame.unsafeInvoke(on: chrome, size, 1)
            let inner = try unsafe screenFrame.unsafeInvoke(on: chrome, size, 1)
            let total = CGSize(width: outer.maxX + outer.minX, height: outer.maxY + outer.minY)
            let scale = 96 / max(total.width, total.height)
            try unsafe setScale.unsafeInvoke(on: view, scale)
            view.frame = CGRect(origin: .zero, size: CGSize(width: total.width * scale, height: total.height * scale))
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw SimulatorError.unavailable("Could not render the simulator's device bezel.")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let image = bitmap.cgImage else {
                throw SimulatorError.unavailable("Could not preserve the simulator's device bezel.")
            }
            return DeviceThumbnailChrome(image: image, mask: mask, size: total, displayRect: inner, cornerRadius: radius)
        }
    }

    func chrome(displaySize: CGSize, cornerRadius: CGFloat) throws -> DeviceThumbnailChrome {
        if let cached, self.displaySize == displaySize, cached.cornerRadius == cornerRadius { return cached }
        let result = try render(displaySize, cornerRadius)
        self.displaySize = displaySize
        cached = result
        return result
    }
}
