import ABIBridge
import AppKit
import Observation
import SwiftUI

/// Hosts the Duo plugin's rotation control and its native orientation state.
@_spi(NeoSimulator)
@MainActor @Observable
public final class NativeDeviceRotationControl {
    public var isEnabled = true
    public var isAvailable: Bool { content != nil }
    @ObservationIgnored public var onError: ((any Error) -> Void)?
    private var content: AnyView?
    @ObservationIgnored private var readControl: (() throws -> AnyView?)?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored public lazy var view: NSView = {
        let host = NSHostingView(rootView: Content(model: self))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 32),
            host.heightAnchor.constraint(equalToConstant: 28),
        ])
        return host
    }()

    static func connect(deviceIdentifier: UUID) async throws -> NativeDeviceRotationControl {
        let result = NativeDeviceRotationControl()
        let runtime = ABIRuntime.shared
        let pluginsType = try await runtime.resolve(.swift(.type("DeviceKit.PluginManager")))
        let shared = try await pluginsType.resolve(.swift(.staticGetter("shared", as: (() -> NativeSwiftValue).self)))
        let plugins = try unsafe shared.unsafeInvoke()
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
        typealias Failure = NativeSwiftClosure<@MainActor @Sendable (any Error) -> Void>
        let errorBody: @MainActor @Sendable (any Error) -> Void = { [weak result] error in result?.onError?(error) }
        let failure = try await bridge(errorBody, runtime: runtime)
            .copyClosure(as: (@MainActor @Sendable (any Error) -> Void).self)
        result.readControl = {
            let owner = try unsafe providers.unsafeInvoke(on: plugins)
            let values = try owner.withCopy { raw -> [Any] in
                guard let sequence = raw as? any Sequence else {
                    throw CLIError.unavailable("native-rotation-providers", "DeviceKit's action providers are unavailable.")
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
                for control in try unsafe controls.unsafeInvoke(on: provider, deviceIdentifier, failure) {
                    let identifier = try unsafe readIdentifier.unsafeInvoke(on: control)
                    guard try unsafe readName.unsafeInvoke(on: identifier) == "com.apple.dt.coredevicepop.actionbar.control.v68.rotate" else { continue }
                    let view = try unsafe readView.unsafeInvoke(on: control)
                    return try view.withCopy { raw in
                        guard let content = raw as? AnyView else {
                            throw CLIError.unavailable("native-rotation-view", "DeviceKit's rotation control is not a SwiftUI view.")
                        }
                        return content
                    }
                }
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

    private struct Content: View {
        weak var model: NativeDeviceRotationControl?
        var body: some View {
            if let model, let content = model.content {
                content
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 15))
                    .disabled(!model.isEnabled)
                    .frame(width: 32, height: 28)
            }
        }
    }
}
