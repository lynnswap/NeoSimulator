import ABIBridge
import Foundation
import NeoSimulatorDeviceIO
import Observation
import SwiftShims
import SwiftUI

/// The camera and the overlay that Device Hub installs above its action bar. DeviceKit owns the capture,
/// its pending file, the banner's layout, and its Finder, sharing and dismissal actions.
@MainActor
package struct NativeScreenshotControls {
    package struct Target: Equatable {
        package enum Display: Equatable {
            case automatic, displayID(UInt32), uniqueID(String), visible([AnyHashable])
        }
        package let device: UUID
        package let display: Display

        package init(device: UUID, display: Display = .automatic) {
            self.device = device
            self.display = display
        }
    }

    private let button: AnyView
    private let identifierType: NativeSwiftType
    package let saves: NativeScreenshotSaves
    package let banner: AnyView

    package static func load(
        for device: UUID, windowID: UUID, onError: @escaping @MainActor @Sendable (any Error) -> Void
    )
        async throws -> Self?
    {
        let runtime = ABIRuntime.shared
        let bindings = try await runtime.prepare { try await NativeActionBarBindings(runtime: $0) }
        let plugins = try unsafe bindings.shared.unsafeInvoke()
        // The manager starts loading its plugins on first access. The first list can still be empty.
        @MainActor struct Item<Value> { let value: Value }
        let primary: Item<Any>? = try await firstAvailable {
            try bindings.providers(in: plugins).first {
                String(reflecting: type(of: $0)) == "DeviceKit.PrimaryControlsProvider"
            }
            .map { Item(value: $0) }
        }
        guard let primary else { return nil }
        guard
            let saves = try await NativeScreenshotSaves.connect(
                plugins: plugins, device: device, windowID: windowID, onError: onError)
        else { return nil }
        let read = try await bindings.controls(of: primary.value, for: device, onError: onError)
        let item = try await firstAvailable {
            try read().first { try bindings.name(of: $0) == "com.apple.devicekit.actionbar.control.screenshot" }.map {
                Item(value: $0)
            }
        }
        guard let item, let overlayType = _typeByName("9DeviceKit20OverlayBannerContentV") as? any View.Type else {
            return nil
        }
        let button = try bindings.view(of: item.value)
        let environment = try await runtime.resolve(.swift(.type("SwiftUI.EnvironmentValues")))
        let uuid = try await runtime.resolve(.swift(.type("Foundation.UUID")))
        let key = try await environment.resolve(
            .swift(.writableKeyPath("(extension in DeviceKit):SwiftUI.EnvironmentValues.windowID", valueType: uuid)))
        guard let path = try key.withCopy({ $0 as? WritableKeyPath<EnvironmentValues, UUID> }) else { return nil }
        let fields = OverlayFields(deviceIdentifier: device, _windowID: Environment(path))
        guard let banner = fields.view(as: overlayType) else { return nil }
        let identifier = try await runtime.resolve(.swift(.type("DeviceKit.DisplayIdentifier")))
        return Self(
            button: button, identifierType: identifier, saves: saves,
            banner: AnyView(banner.environment(path, windowID)))
    }

    private static func firstAvailable<Value: Sendable>(_ read: @escaping @MainActor @Sendable () throws -> Value?)
        async throws -> Value?
    {
        for try await case let value? in Observations(read) { return value }
        return nil
    }

    /// The action bar passes the displays shown by the canvas through this environment key.
    /// A Resize App display has a unique ID, while a simulator framebuffer has a numeric ID.
    package func camera(showing display: Target.Display) throws -> AnyView? {
        guard display != .automatic else { return button }
        // The camera already stores DeviceKit's writable environment key path. It has no exported getter.
        let path = Mirror(reflecting: button).descendant(
            "storage", "view", "_visibleDisplayIdentifiers", "content", "keyPath")
        func identifier<Value>(_ name: String, _ value: Value) throws -> [Any] {
            let wrapped = try identifierType.makeEnumCaseAndWait(named: name, associatedValues: value)
            return try wrapped.withCopy { [$0] }
        }
        let identifiers: [Any]
        switch display {
        case .visible(let displays): identifiers = displays.map(\.base)
        case .displayID(let id): identifiers = try identifier("displayID", id)
        case .uniqueID(let id): identifiers = try identifier("uniqueID", id)
        case .automatic: return button
        }
        func configure<ID>(_ first: ID) -> AnyView? {
            guard let key = path as? WritableKeyPath<EnvironmentValues, [ID]>, let values = identifiers as? [ID] else {
                return nil
            }
            return AnyView(button.environment(key, values))
        }
        guard let first = identifiers.first else { return button }
        return _openExistential(first, do: configure)
    }

    /// OverlayBannerContent has no exported initializer. Match its complete reflected storage before passing
    /// the initialized fields to its own SwiftUI.View witness. SwiftUI and DeviceKit perform all layout.
    private struct OverlayFields {
        let deviceIdentifier: UUID
        let _windowID: Environment<UUID>

        func view<V: View>(as type: V.Type) -> AnyView? {
            guard fieldCount(type) == 2, MemoryLayout<V>.size == MemoryLayout<Self>.size,
                MemoryLayout<V>.alignment == MemoryLayout<Self>.alignment
            else { return nil }
            for (index, expected) in Mirror(reflecting: self).children.enumerated() {
                var field = _FieldReflectionMetadata()
                let actual = fieldType(type, index, &field)
                defer { field.freeFunc?(field.name) }
                let offset =
                    index == 0
                    ? MemoryLayout<Self>.offset(of: \.deviceIdentifier) : MemoryLayout<Self>.offset(of: \._windowID)
                guard actual == Swift.type(of: expected.value), let name = field.name,
                    String(cString: name) == expected.label,
                    fieldOffset(type, index) == offset
                else { return nil }
            }
            return AnyView(unsafeBitCast(self, to: V.self))
        }
    }
}

@_silgen_name("swift_reflectionMirror_recursiveCount")
private func fieldCount(_ type: Any.Type) -> Int
@_silgen_name("swift_reflectionMirror_recursiveChildMetadata")
private func fieldType(_ type: Any.Type, _ index: Int, _ metadata: UnsafeMutablePointer<_FieldReflectionMetadata>)
    -> Any.Type
@_silgen_name("swift_reflectionMirror_recursiveChildOffset")
private func fieldOffset(_ type: Any.Type, _ index: Int) -> Int

/// DeviceKit's camera starts child tasks for the capture and the saved banner's file handoff.
/// Its tasks inherit this per-press lifetime, including when another capture replaces the banner.
@MainActor
package final class NativeScreenshotSaves {
    private final class Lifetime: Sendable {
        let device: UUID
        let pixels: AsyncStream<Void>.Continuation
        let completion: AsyncStream<Void>.Continuation
        init(device: UUID, pixels: AsyncStream<Void>.Continuation, completion: AsyncStream<Void>.Continuation) {
            self.device = device
            self.pixels = pixels
            self.completion = completion
        }
        deinit { pixels.finish(); completion.finish() }
    }

    @TaskLocal nonisolated private static var lifetime: Lifetime?
    private struct Pending {
        let owner: NativeScreenshotSaves
        let pixels: Task<Void, Never>
        let task: Task<Void, Never>
    }
    private static var pending: [UUID: Pending] = [:]
    private let device: UUID
    private let onError: @MainActor (any Error) -> Void

    private let bannerIsVisible: @MainActor () throws -> Bool
    private var observingBanner = false

    init(
        device: UUID, onError: @escaping @MainActor (any Error) -> Void,
        bannerIsVisible: @escaping @MainActor () throws -> Bool
    ) {
        self.device = device
        self.onError = onError
        self.bannerIsVisible = bannerIsVisible
    }

    fileprivate static func connect(
        plugins: NativeSwiftValue, device: UUID, windowID: UUID,
        onError: @escaping @MainActor (any Error) -> Void
    ) async throws
        -> NativeScreenshotSaves?
    {
        let runtime = ABIRuntime.shared
        let read = try await plugins.type.resolve(.swift(.getter("bannerProviders", as: (() -> NativeSwiftValue).self)))
        let providers = try NativeActionBarBindings.elements(of: unsafe read.unsafeInvoke(on: plugins))
        guard
            let saved = providers.first(where: {
                String(reflecting: type(of: $0)) == "DeviceKit.ScreenCaptureSavedBanner"
            })
        else { return nil }
        func copy<V>(_ value: V) async throws -> NativeSwiftValue {
            try await NativeActionBarBindings.bridge(value, runtime: runtime)
        }
        let provider = try await _openExistential(saved, do: copy).copyUnderlyingValue()
        let context = try await runtime.resolve(.swift(.type("DeviceKit.BannerProviderContext")))
        let abi = [context: try NativeType.opaque(named: context.name)]
        let make = try await context.resolve(
            .swift(
                .initializer("init(deviceID:windowID:)", as: ((UUID, UUID) -> NativeSwiftValue).self, valueABIs: abi)))
        let value = try unsafe make.unsafeInvoke(device, windowID)
        let shown = try await provider.type.resolve(
            .swift(
                .method(
                    "DeviceKit.BannerProvider.isVisible(in:)", as: ((NativeSwiftValue) -> Bool).self, valueABIs: abi)))
        return NativeScreenshotSaves(device: device, onError: onError) {
            try unsafe shown.unsafeInvoke(on: provider, value)
        }
    }

    // The one-shot callback runs in the task that changes DeviceKit's banner state. Its task-local
    // identifies the press even if a subsequent main-actor pass sees several updates together.
    private func observePixels() {
        guard !observingBanner else { return }
        observingBanner = true
        _ = withObservationTracking {
            try? bannerIsVisible()
        } onChange: { [weak self] in
            // DeviceKit publishes its camera results on the main thread. Re-arm before returning
            // to the writer so two presses can publish in the same main-actor turn.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.observeNextPublication() }
            } else {
                Task { @MainActor [weak self] in self?.observeNextPublication() }
            }
            guard let capture = Self.lifetime else { return }
            Task { @MainActor [weak self] in
                guard let self, capture.device == device, (try? bannerIsVisible()) == true else { return }
                capture.pixels.finish()
            }
        }
    }

    private func observeNextPublication() {
        observingBanner = false
        if Self.pending.values.contains(where: { $0.owner === self }) { observePixels() }
    }

    package func take(_ trigger: () -> Void) {
        let id = UUID()
        let (frames, pixels) = AsyncStream<Void>.makeStream()
        let (work, completion) = AsyncStream<Void>.makeStream()
        let copied = Task { for await _ in frames {} }
        let task = Task {
            for await _ in work {}
            Self.pending.removeValue(forKey: id)
        }
        Self.pending[id] = Pending(owner: self, pixels: copied, task: task)
        observePixels()
        Self.$lifetime.withValue(Lifetime(device: device, pixels: pixels, completion: completion), operation: trigger)
    }

    /// Keeps the display alive for the presses accepted before a disconnect or display change.
    package static func acquiring(on device: UUID) -> Task<Void, Never>? {
        let captures = pending.values.filter { $0.owner.device == device }
        guard !captures.isEmpty else { return nil }
        return Task {
            let deadline = ContinuousClock.now + DeviceOperationLimit.bridge
            for capture in captures where !(await capture.pixels.ends(before: deadline)) {
                capture.owner.onError(RemoteScreenError.unavailable("native-capture-timeout", capture.owner.recovery))
                return
            }
        }
    }

    private var recovery: String {
        let folder = FileManager.default.temporaryDirectory.appending(path: "com.apple.dt.Devices.ScreenCaptures")
        return "DeviceKit did not finish saving a screenshot of \(device). Check \(folder.path) for pending captures."
    }

    package static func finish(before deadline: ContinuousClock.Instant) async -> String? {
        while let capture = pending.values.first {
            if !(await capture.task.ends(before: deadline)) { return capture.owner.recovery }
        }
        return nil
    }
}
