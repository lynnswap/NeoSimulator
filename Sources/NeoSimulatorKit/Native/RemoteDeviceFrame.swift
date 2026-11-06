import ABIBridge
import AppKit
import Observation
import OSLog
import SwiftUI

/// A device's primary display, as DeviceKit sizes and identifies its chrome.
package struct RemoteDeviceDisplay: Equatable, Sendable {
    package let pixelSize: CGSize
    package let scale: CGFloat
    package let chromeIdentifier: String?
    package let maskIdentifier: String?
}

/// A chrome button's HID usage, as its chrome.json declares it.
package struct RemoteDeviceChromeButton: Equatable, Sendable {
    package let usagePage: Int
    package let usage: Int
}

/// The installed DeviceKit artwork for one display: its chrome bundle and framebuffer mask.
package struct RemoteDeviceChromeResources: Equatable {
    package static let deviceKitDirectory = URL(fileURLWithPath: "/Library/Developer/DeviceKit", isDirectory: true)

    package let bundle: URL
    package let mask: URL?
    package let buttons: [String: RemoteDeviceChromeButton]

    /// Prefers the identifiers the display reports, then the product's entry in DeviceKit's chrome map, as DeviceKit does.
    package init?(display: RemoteDeviceDisplay, productType: String?, directory: URL = deviceKitDirectory) throws {
        let map = try Self.chromeMap(in: directory)[productType ?? ""]
        guard let identifier = display.chromeIdentifier ?? map?["ChromeIdentifier"],
              let bundle = try Self.chromeBundle(identifier, in: directory) else { return nil }
        self.bundle = bundle
        mask = (display.maskIdentifier ?? map?["FramebufferIdentifier"]).map {
            directory.appendingPathComponent("FramebufferMasks/\($0).pdf")
        }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        buttons = try Self.buttons(in: bundle)
    }

    private static func chromeMap(in directory: URL) throws -> [String: [String: String]] {
        let url = directory.appendingPathComponent("chrome_map.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        guard let map = value as? [String: [String: Any]] else {
            throw CLIError.io("device-chrome-map", "DeviceKit's chrome map has an unexpected format.")
        }
        return map.mapValues { $0.compactMapValues { $0 as? String } }
    }

    private static func chromeBundle(_ identifier: String, in directory: URL) throws -> URL? {
        let chrome = directory.appendingPathComponent("Chrome", isDirectory: true)
        guard FileManager.default.fileExists(atPath: chrome.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(at: chrome, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "devicechrome" && Bundle(url: $0)?.bundleIdentifier == identifier }
    }

    private static func buttons(in bundle: URL) throws -> [String: RemoteDeviceChromeButton] {
        struct Chrome: Decodable {
            struct Input: Decodable { let name: String; let type: String; let usagePage: Int?; let usage: Int? }
            let inputs: [Input]?
        }
        let url = bundle.appendingPathComponent("Contents/Resources/chrome.json")
        let chrome = try JSONDecoder().decode(Chrome.self, from: Data(contentsOf: url))
        // DeviceKit sends presses only for buttons; switches report their position instead.
        return Dictionary(uniqueKeysWithValues: (chrome.inputs ?? []).compactMap { input in
            guard input.type == "button", let page = input.usagePage, let usage = input.usage else { return nil }
            return (input.name, RemoteDeviceChromeButton(usagePage: page, usage: usage))
        })
    }
}

/// DeviceKit's chrome view and layout model, without DeviceKit's display stream.
@MainActor
package final class NativeDeviceChrome {
    /// The chrome's size at the fitted scale, and its display's frame from the chrome's top-left corner.
    package struct Layout: Equatable {
        package let size: CGSize
        package let screen: CGRect
    }

    package enum ButtonEvent {
        case pressed(RemoteDeviceChromeButton, RemoteDeviceButtonState)
        case failed(any Error)
    }

    package let view: NSView
    package let mask: NSImage?
    package var onButton: ((ButtonEvent) -> Void)?
    package var angle: Double {
        get { presentation.angle }
        set { presentation.angle = newValue }
    }
    private let presentation = NativeChromePresentation()
    private let model: NativeSwiftValue
    private let chrome: NativeSwiftValue
    private let makeSize: NativeSwiftFunction<(CGSize, CGFloat) -> NativeSwiftValue>
    private let apply: NativeSwiftMethod<(NativeSwiftValue?, NativeSwiftValue?, CGSize) -> Void>
    private let readLayout: NativeSwiftMethod<() -> NativeSwiftValue?>
    private let fullFrame: NativeSwiftMethod<() -> CGRect>
    private let framebufferFrame: NativeSwiftMethod<() -> CGRect>
    private var applied: (display: RemoteDeviceDisplay, size: CGSize, layout: Layout?)?
    private var buttonEvents: Task<Void, Never>?

    package init(resources: RemoteDeviceChromeResources) async throws {
        guard let bundle = Bundle(url: resources.bundle) else {
            throw CLIError.unavailable("device-chrome", "The device's frame artwork could not be opened.")
        }
        let runtime = ABIRuntime.shared
        let modelType = try await runtime.resolve(.swift(.type("DeviceKit.DisplayViewModel")))
        let chromeType = try await runtime.resolve(.swift(.type("DeviceKit.DisplayChrome")))
        let inputType = try await runtime.resolve(.swift(.type("DeviceKit.DisplayChrome.Input")))
        let sizeType = try await runtime.resolve(.swift(.type("DeviceKit.DisplaySize")))
        let layoutType = try await runtime.resolve(.swift(.type("DeviceKit.DisplayViewLayout")))
        let viewType = try await runtime.resolve(.swift(.type("DeviceKit.ChromeView")))
        // These DeviceKit values are resilient; their exported members pass them indirectly.
        let abis = try Dictionary(uniqueKeysWithValues: [chromeType, inputType, sizeType, layoutType, viewType]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        let makeModel = try await modelType.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self)))
        let makeChrome = try await chromeType.resolve(.swift(.initializer("init(bundle:)",
            as: ((Bundle) throws -> NativeSwiftValue).self, valueABIs: abis)))
        let makeView = try await viewType.resolve(.swift(.initializer("init(viewModel:)",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: abis)))
        makeSize = try await sizeType.resolve(.swift(.initializer("init(pixelSize:uiScale:)",
            as: ((CGSize, CGFloat) -> NativeSwiftValue).self, valueABIs: abis)))
        apply = try await modelType.resolve(.swift(.method("apply(chrome:displaySize:containerSize:)",
            as: ((NativeSwiftValue?, NativeSwiftValue?, CGSize) -> Void).self, valueABIs: abis)))
        readLayout = try await modelType.resolve(.swift(.getter("viewLayout", as: (() -> NativeSwiftValue?).self, valueABIs: abis)))
        fullFrame = try await layoutType.resolve(.swift(.getter("fullFrame", as: (() -> CGRect).self,
            valueABIs: abis, receiverABI: abis[layoutType])))
        framebufferFrame = try await layoutType.resolve(.swift(.getter("framebufferFrame", as: (() -> CGRect).self,
            valueABIs: abis, receiverABI: abis[layoutType])))
        let name = try await inputType.resolve(.swift(.getter("name", as: (() -> String).self,
            valueABIs: abis, receiverABI: abis[inputType])))
        typealias Handler = NativeSwiftClosure<(NativeSwiftValue) -> Void>
        let setDown = try await modelType.resolve(.swift(.setter("onButtonDown", as: ((Handler?) -> Void).self, valueABIs: abis)))
        let setUp = try await modelType.resolve(.swift(.setter("onButtonUp", as: ((Handler?) -> Void).self, valueABIs: abis)))
        model = try unsafe makeModel.unsafeInvoke()
        chrome = try unsafe makeChrome.unsafeInvoke(bundle)
        mask = resources.mask.flatMap(NSImage.init(contentsOf:))
        // DeviceKit calls these from its chrome view; the stream keeps each press ordered before its release.
        let (events, continuation) = AsyncStream.makeStream(of: Result<(String, RemoteDeviceButtonState), any Error>.self)
        func handler(_ state: RemoteDeviceButtonState) throws -> Handler {
            try Handler { input in continuation.yield(Result { (try unsafe name.unsafeInvoke(on: input), state) }) }
        }
        try unsafe setDown.unsafeInvoke(on: model, handler(.down))
        try unsafe setUp.unsafeInvoke(on: model, handler(.up))
        // The view's initializer consumes its argument; the model stays with this owner for layout.
        let content = try unsafe makeView.unsafeInvoke(model.copy()).withCopy { raw -> AnyView in
            guard let view = raw as? any View else {
                throw CLIError.unavailable("device-chrome-view", "DeviceKit returned a frame that is not a SwiftUI view.")
            }
            return AnyView(view)
        }
        let hosting = NSHostingView(rootView: NativeChromeRoot(content: content, presentation: presentation))
        hosting.sizingOptions = []
        view = hosting
        let buttons = resources.buttons
        buttonEvents = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .success(let (name, state)):
                    if let button = buttons[name] { self.onButton?(.pressed(button, state)) }
                case .failure(let error): self.onButton?(.failed(error))
                }
            }
        }
    }

    isolated deinit { buttonEvents?.cancel() }

    /// Fits the chrome to `size`, in the display's native orientation.
    package func layout(for display: RemoteDeviceDisplay, fitting size: CGSize) throws -> Layout? {
        if let applied, applied.display == display, applied.size == size { return applied.layout }
        let displaySize = try unsafe makeSize.unsafeInvoke(display.pixelSize, display.scale)
        try unsafe apply.unsafeInvoke(on: model, chrome, displaySize, size)
        let layout = try unsafe readLayout.unsafeInvoke(on: model).map {
            Layout(size: try unsafe fullFrame.unsafeInvoke(on: $0).size, screen: try unsafe framebufferFrame.unsafeInvoke(on: $0))
        }
        applied = (display, size, layout)
        return layout
    }
}

@MainActor @Observable
private final class NativeChromePresentation {
    var angle: Double = 0
}

private struct NativeChromeRoot: View {
    let content: AnyView
    let presentation: NativeChromePresentation
    var body: some View {
        // DeviceKit's display angles are SwiftUI angles, so the chrome turns with the screen.
        content
            .rotationEffect(.degrees(presentation.angle))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows a physical device's DeviceKit chrome around the view its screen transports draw in.
@MainActor
package final class RemoteDeviceFrameView: NSView {
    private static let logger = Logger(subsystem: "dev.lynnswap.NeoSimulator", category: "RemoteScreen")

    /// Covers the device's display; transports add their content here.
    package let screen: NSView = RemoteDeviceScreenView()
    /// The display's quarter-turn orientation, as DeviceKit reports it.
    package var angle: CGFloat = 0 { didSet { if angle != oldValue { needsLayout = true } } }
    /// A resized app's dedicated display has no device around it.
    package var showsChrome = true { didSet { if showsChrome != oldValue { needsLayout = true } } }
    package private(set) var chrome: NativeDeviceChrome?
    private var display: RemoteDeviceDisplay?
    private let maskLayer = CALayer()

    package init() {
        super.init(frame: .zero)
        wantsLayer = true
        screen.wantsLayer = true
        screen.layer?.backgroundColor = NSColor.black.cgColor
        screen.autoresizingMask = [.width, .height]
        maskLayer.contentsGravity = .resize
        addSubview(screen)
    }

    package required init?(coder: NSCoder) { nil }

    package func show(_ chrome: NativeDeviceChrome, for display: RemoteDeviceDisplay) {
        self.chrome?.view.removeFromSuperview()
        self.chrome = chrome
        self.display = display
        maskLayer.contents = chrome.mask
        chrome.view.autoresizingMask = [.width, .height]
        addSubview(chrome.view, positioned: .below, relativeTo: screen)
        needsLayout = true
    }

    package override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard showsChrome, let chrome, let display, let layout = fittedLayout(chrome, display) else {
            chrome?.view.isHidden = true
            screen.frame = bounds
            screen.layer?.mask = nil
            return
        }
        // The device turns about its center, as DeviceKit's rotation effect does. AppKit's origin is at the
        // bottom left, so the chrome's top-left offsets and SwiftUI angle change sign here.
        let radians = -angle * .pi / 180
        let center = CGPoint(x: layout.screen.midX - layout.size.width / 2, y: layout.size.height / 2 - layout.screen.midY)
            .applying(CGAffineTransform(rotationAngle: radians))
        let turned = CGRect(origin: .zero, size: layout.screen.size).applying(CGAffineTransform(rotationAngle: radians)).size
        screen.frame = CGRect(x: bounds.midX + center.x - turned.width / 2, y: bounds.midY + center.y - turned.height / 2,
                              width: turned.width, height: turned.height)
        chrome.view.frame = bounds
        chrome.view.isHidden = false
        chrome.angle = angle
        maskLayer.bounds = CGRect(origin: .zero, size: layout.screen.size)
        maskLayer.position = CGPoint(x: screen.bounds.midX, y: screen.bounds.midY)
        maskLayer.setAffineTransform(CGAffineTransform(rotationAngle: radians))
        screen.layer?.mask = chrome.mask == nil ? nil : maskLayer
    }

    private func fittedLayout(_ chrome: NativeDeviceChrome, _ display: RemoteDeviceDisplay) -> NativeDeviceChrome.Layout? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // DeviceKit lays the chrome out in the display's native orientation.
        let sideways = Int((abs(angle) / 90).rounded()) % 2 == 1
        let size = sideways ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        do { return try chrome.layout(for: display, fitting: size) }
        catch {
            Self.logger.error("The device frame could not be laid out: \(error.localizedDescription, privacy: .public)")
            chrome.view.removeFromSuperview()
            self.chrome = nil
            return nil
        }
    }
}

/// Keeps a transport's content on the display's exact frame. AppKit's autoresizing aligns each edge to the
/// backing pixel grid, which would move the shown display and its input off a screen placed between pixels.
private final class RemoteDeviceScreenView: NSView {
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for subview in subviews { subview.frame = bounds }
    }
}
