import ABIBridge
import AppKit
import Observation
import SwiftUI

/// Hosts the Duo plugin's rotation and posture controls with their native orientation state.
@MainActor @Observable
package final class NativeDevicePoseControls {
    package var isEnabled = true
    package var isAvailable: Bool { content != nil }
    /// Receives the controls' failures, including one from before the window that presents them connected.
    @ObservationIgnored package var onError: ((any Error) -> Void)? {
        didSet {
            guard let onError, let failure = unreportedFailure else { return }
            unreportedFailure = nil
            onError(failure)
        }
    }
    package struct Controls {
        package let rotation: AnyView
        package let postures: AnyView
        package let divider: AnyView?

        package init(rotation: AnyView, postures: AnyView, divider: AnyView?) {
            self.rotation = rotation
            self.postures = postures
            self.divider = divider
        }
    }
    /// Provider content without the standalone toolbar's sizing or button style.
    package var actionBarControls: [AnyView] {
        guard let content else { return [] }
        return [content.rotation] + (content.divider.map { [$0] } ?? []) + [content.postures]
    }

    private var content: Controls?
    @ObservationIgnored private var readProviders: (() throws -> [Any])?
    @ObservationIgnored private var prepareControls: (@MainActor ([Any]) async throws -> (() throws -> Controls?)?)?
    @ObservationIgnored private var discoveryGeneration = 0
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var unreportedFailure: (any Error)?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored package lazy var rotationView: NSView = makeView(postures: false)
    @ObservationIgnored package lazy var postureView: NSView = makeView(postures: true)

    private func makeView(postures: Bool) -> NSView {
        let host = NSHostingView(rootView: Content(model: self, postures: postures))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: postures ? 100 : 32),
            host.heightAnchor.constraint(equalToConstant: 28),
        ])
        return host
    }

    package struct Bindings {
        package let shared: NativeSwiftFunction<() -> NativeSwiftValue>
        package let providers: NativeSwiftMethod<() -> NativeSwiftValue>
        package let readIdentifier: NativeSwiftMethod<() -> NativeSwiftValue>
        package let readName: NativeSwiftMethod<() -> String>
        package let readView: NativeSwiftMethod<() -> NativeSwiftValue>

        package init(runtime: ABIRuntime) async throws {
            let pluginsType = try await runtime.resolve(.swift(.type("DeviceKit.PluginManager")))
            let shared = try await pluginsType.resolve(.swift(.staticGetter("shared", as: (() -> NativeSwiftValue).self)))
            let providers = try await pluginsType.resolve(.swift(.getter("actionBarControlProviders", as: (() -> NativeSwiftValue).self)))
            let controlType = try await runtime.resolve(.swift(.type("DeviceKit.ActionBarControl")))
            let identifierType = try await runtime.resolve(.swift(.type("DeviceKit.ActionBarControlIdentifier")))
            let abis = try Dictionary(uniqueKeysWithValues: [controlType, identifierType]
                .map { ($0, try NativeType.opaque(named: $0.name)) })
            let readIdentifier = try await controlType.resolve(.swift(.getter("id", as: (() -> NativeSwiftValue).self,
                valueABIs: abis, receiverABI: .opaque(named: controlType.name))))
            let readName = try await identifierType.resolve(.swift(.getter("id", as: (() -> String).self,
                receiverABI: .opaque(named: identifierType.name))))
            let anyView = try await runtime.resolve(.swift(.type("SwiftUI.AnyView")))
            // The SDK declares AnyView @frozen with one class-reference field.
            let readView = try await controlType.resolve(.swift(.getter("view", as: (() -> NativeSwiftValue).self,
                valueABIs: [anyView: try .structure(named: anyView.name, fields: [.pointer]),
                            controlType: try .opaque(named: controlType.name)], receiverABI: .opaque(named: controlType.name))))
            self.shared = shared
            self.providers = providers
            self.readIdentifier = readIdentifier
            self.readName = readName
            self.readView = readView
        }
    }

    /// Starts finding the device's controls, which the screen they accompany does not wait for: they appear when found.
    package convenience init(deviceIdentifier: UUID) {
        self.init { try await $0.connect(deviceIdentifier: deviceIdentifier) }
    }

    /// Runs `prepare` until `disconnect()`, keeping its failure for `onError`.
    package init(prepare: @escaping @MainActor (NativeDevicePoseControls) async throws -> Void) {
        preparation = Task { [weak self] in
            guard let self else { return }
            do { try await prepare(self) }
            catch is CancellationError {}
            catch { report(error) }
        }
    }

    private func connect(deviceIdentifier: UUID) async throws {
        let runtime = ABIRuntime.shared
        let bindings = try await Bindings(runtime: runtime)
        let plugins = try unsafe bindings.shared.unsafeInvoke()
        typealias Failure = NativeSwiftClosure<@MainActor @Sendable (any Error) -> Void>
        let errorBody: @MainActor @Sendable (any Error) -> Void = { [weak self] error in self?.report(error) }
        let failure = try await Self.bridge(errorBody, runtime: runtime)
            .copyClosure(as: (@MainActor @Sendable (any Error) -> Void).self)
        guard !stopped else { return }
        try await discover(readProviders: {
            let owner = try unsafe bindings.providers.unsafeInvoke(on: plugins)
            let values = try owner.withCopy { raw -> [Any] in
                guard let sequence = raw as? any Sequence else {
                    throw CLIError.unavailable("native-pose-providers", "DeviceKit's action providers are unavailable.")
                }
                func elements<S: Sequence>(_ sequence: S) -> [Any] { sequence.map { $0 } }
                return elements(sequence)
            }
            return values
        }, prepareControls: { values in
            for value in values where String(reflecting: type(of: value)) == "CoreDevicePopDeviceKitExtension.PosesActionBarControlProvider" {
                @MainActor func copy<Value>(_ value: Value) async throws -> NativeSwiftValue { try await Self.bridge(value, runtime: runtime) }
                let provider = try await _openExistential(value, do: copy).copyUnderlyingValue()
                let controls = try await provider.type.resolve(.swift(.method(
                    "DeviceKit.ActionBarControlProvider.controls(deviceID:onError:)",
                    as: ((UUID, Failure) -> [NativeSwiftValue]).self)))
                return {
                    var rotation: AnyView?, postures: AnyView?, divider: AnyView?
                    for control in try unsafe controls.unsafeInvoke(on: provider, deviceIdentifier, failure) {
                        let identifier = try unsafe bindings.readIdentifier.unsafeInvoke(on: control)
                        let name = try unsafe bindings.readName.unsafeInvoke(on: identifier)
                        guard name == "com.apple.dt.coredevicepop.actionbar.control.v68.rotate" ||
                                name == "com.apple.dt.coredevicepop.actionbar.control.v68.poses" ||
                                name == "com.apple.dt.coredevicepop.actionbar.control.v68.rotateDivider" else { continue }
                        let view = try unsafe bindings.readView.unsafeInvoke(on: control)
                        let content = try view.withCopy { raw in
                            guard let content = raw as? AnyView else {
                                throw CLIError.unavailable("native-pose-view", "DeviceKit's pose control is not a SwiftUI view.")
                            }
                            return content
                        }
                        if name.hasSuffix(".rotate") { rotation = content }
                        else if name.hasSuffix(".rotateDivider") { divider = content }
                        else { postures = content }
                    }
                    guard let rotation, let postures else { return nil }
                    return Controls(rotation: rotation, postures: postures, divider: divider)
                }
            }
            return nil
        })
    }

    /// Finds the controls now and whenever what `readProviders` or the reader from `prepareControls` read changes. The
    /// reader that `prepareControls` returns reads the provider's controls, which it does not offer while CoreDevice
    /// reports the device as shut down.
    package func discover(readProviders: @escaping () throws -> [Any],
                          prepareControls: @escaping @MainActor ([Any]) async throws -> (() throws -> Controls?)?) async throws {
        self.readProviders = readProviders
        self.prepareControls = prepareControls
        try await discover()
    }

    private func report(_ error: any Error) {
        guard !stopped else { return }
        if let onError { onError(error) } else { unreportedFailure = error }
    }

    private static func bridge<Value>(_ value: Value, runtime: ABIRuntime) async throws -> NativeSwiftValue {
        let array = try await runtime.resolve(.swift(.type("Swift.Array", genericArguments: [.type(Value.self)])))
        let read = try await array.resolve(.swift(.getter("Swift.Array.subscript.getter : (Swift.Int) -> A",
            as: ((Int) -> NativeSwiftValue).self)))
        return try unsafe read.unsafeInvoke(on: [value], 0)
    }

    private func discover() async throws {
        guard !stopped, content == nil, let readProviders, let prepareControls else { return }
        discoveryGeneration += 1
        let generation = discoveryGeneration
        let providers = discoveringAgainOnChange { Result { try readProviders() } }
        let readControls = try await prepareControls(providers.get())
        guard !stopped, discoveryGeneration == generation, content == nil, let readControls else { return }
        if let control = try discoveringAgainOnChange({ Result { try readControls() } }).get() {
            content = control
            self.readProviders = nil
            self.prepareControls = nil
        }
    }

    private func discoveringAgainOnChange<Value>(_ read: () -> Value) -> Value {
        withObservationTracking(read) { [weak self] in
            Task { @MainActor [weak self] in
                do { try await self?.discover() }
                catch { self?.report(error) }
            }
        }
    }

    package func disconnect() {
        stopped = true
        preparation?.cancel()
        preparation = nil
        unreportedFailure = nil
        discoveryGeneration += 1
        readProviders = nil
        prepareControls = nil
        content = nil
        onError = nil
    }

    // These bounds belong to the standalone renderer toolbar; the canvas styles raw controls.
    private struct ToolbarButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
    }

    private struct Content: View {
        weak var model: NativeDevicePoseControls?
        let postures: Bool
        var body: some View {
            if let model, let content = model.content {
                (postures ? content.postures : content.rotation)
                    .labelStyle(.iconOnly)
                    .buttonStyle(ToolbarButtonStyle())
                    .font(.system(size: 15))
                    .disabled(!model.isEnabled)
                    .frame(width: postures ? 100 : 32, height: 28)
            }
        }
    }
}
