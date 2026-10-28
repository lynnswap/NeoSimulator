import ABIBridge
import AppKit
import Observation
import SwiftUI

/// Hosts the Duo plugin's rotation and posture controls with their native orientation state.
@_spi(NeoSimulator)
@MainActor @Observable
public final class NativeDevicePoseControls {
    public var isEnabled = true
    public var isAvailable: Bool { content != nil }
    @ObservationIgnored public var onError: ((any Error) -> Void)?
    private struct Controls {
        let rotation: AnyView
        let postures: AnyView
    }
    private var content: Controls?
    @ObservationIgnored private var readControl: (() throws -> Controls?)?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored public lazy var rotationView: NSView = makeView(postures: false)
    @ObservationIgnored public lazy var postureView: NSView = makeView(postures: true)

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

    struct Bindings {
        let shared: NativeSwiftFunction<() -> NativeSwiftValue>
        let providers: NativeSwiftMethod<() -> NativeSwiftValue>
        let readIdentifier: NativeSwiftMethod<() -> NativeSwiftValue>
        let readName: NativeSwiftMethod<() -> String>
        let readView: NativeSwiftMethod<() -> NativeSwiftValue>

        init(runtime: ABIRuntime) async throws {
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

    static func connect(deviceIdentifier: UUID) async throws -> NativeDevicePoseControls {
        let result = NativeDevicePoseControls()
        let runtime = ABIRuntime.shared
        let bindings = try await Bindings(runtime: runtime)
        let plugins = try unsafe bindings.shared.unsafeInvoke()
        typealias Failure = NativeSwiftClosure<@MainActor @Sendable (any Error) -> Void>
        let errorBody: @MainActor @Sendable (any Error) -> Void = { [weak result] error in result?.onError?(error) }
        let failure = try await bridge(errorBody, runtime: runtime)
            .copyClosure(as: (@MainActor @Sendable (any Error) -> Void).self)
        result.readControl = {
            let owner = try unsafe bindings.providers.unsafeInvoke(on: plugins)
            let values = try owner.withCopy { raw -> [Any] in
                guard let sequence = raw as? any Sequence else {
                    throw CLIError.unavailable("native-pose-providers", "DeviceKit's action providers are unavailable.")
                }
                func elements<S: Sequence>(_ sequence: S) -> [Any] { sequence.map { $0 } }
                return elements(sequence)
            }
            for value in values where String(reflecting: type(of: value)) == "CoreDevicePopDeviceKitExtension.PosesActionBarControlProvider" {
                @MainActor func copy<Value>(_ value: Value) throws -> NativeSwiftValue { try bridge(value, runtime: runtime) }
                let provider = try _openExistential(value, do: copy).copyUnderlyingValue()
                let controls = try provider.type.resolveAndWait(.swift(.method(
                    "DeviceKit.ActionBarControlProvider.controls(deviceID:onError:)",
                    as: ((UUID, Failure) -> [NativeSwiftValue]).self)))
                var rotation: AnyView?, postures: AnyView?
                for control in try unsafe controls.unsafeInvoke(on: provider, deviceIdentifier, failure) {
                    let identifier = try unsafe bindings.readIdentifier.unsafeInvoke(on: control)
                    let name = try unsafe bindings.readName.unsafeInvoke(on: identifier)
                    guard name == "com.apple.dt.coredevicepop.actionbar.control.v68.rotate" ||
                            name == "com.apple.dt.coredevicepop.actionbar.control.v68.poses" else { continue }
                    let view = try unsafe bindings.readView.unsafeInvoke(on: control)
                    let content = try view.withCopy { raw in
                        guard let content = raw as? AnyView else {
                            throw CLIError.unavailable("native-pose-view", "DeviceKit's pose control is not a SwiftUI view.")
                        }
                        return content
                    }
                    if name.hasSuffix(".rotate") { rotation = content } else { postures = content }
                }
                if let rotation, let postures { return Controls(rotation: rotation, postures: postures) }
            }
            return nil
        }
        try result.discover()
        return result
    }

    private static func bridge<Value>(_ value: Value, runtime: ABIRuntime) throws -> NativeSwiftValue {
        let array = try runtime.resolveAndWait(.swift(.type("Swift.Array", genericArguments: [.type(Value.self)])))
        let read = try array.resolveAndWait(.swift(.getter("Swift.Array.subscript.getter : (Swift.Int) -> A",
            as: ((Int) -> NativeSwiftValue).self)))
        return try unsafe read.unsafeInvoke(on: [value], 0)
    }

    private func discover() throws {
        guard !stopped, content == nil, let readControl else { return }
        let result = withObservationTracking {
            Result { try readControl() }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                do { try self?.discover() }
                catch { self?.onError?(error) }
            }
        }
        if let control = try result.get() {
            content = control
            self.readControl = nil
        }
    }

    public func disconnect() {
        stopped = true
        readControl = nil
        content = nil
        onError = nil
    }

    // The provider inherits 32 × 28 button bounds from Device Hub's action bar.
    private struct ActionButtonStyle: ButtonStyle {
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
                    .buttonStyle(ActionButtonStyle())
                    .font(.system(size: 15))
                    .disabled(!model.isEnabled)
                    .frame(width: postures ? 100 : 32, height: 28)
            }
        }
    }
}
