import ABIBridge
import Foundation
import NeoSimulatorDeviceIO
import SwiftUI

struct NativeActionBarBindings {
    let shared: NativeSwiftFunction<() -> NativeSwiftValue>
    let providers: NativeSwiftMethod<() -> NativeSwiftValue>
    let readIdentifier: NativeSwiftMethod<() -> NativeSwiftValue>
    let readName: NativeSwiftMethod<() -> String>
    let readView: NativeSwiftMethod<() -> NativeSwiftValue>

    init(runtime: ABIRuntime) async throws {
        let pluginsType = try await runtime.resolve(.swift(.type("DeviceKit.PluginManager")))
        let shared = try await pluginsType.resolve(.swift(.staticGetter("shared", as: (() -> NativeSwiftValue).self)))
        let providers = try await pluginsType.resolve(
            .swift(.getter("actionBarControlProviders", as: (() -> NativeSwiftValue).self)))
        let controlType = try await runtime.resolve(.swift(.type("DeviceKit.ActionBarControl")))
        let identifierType = try await runtime.resolve(.swift(.type("DeviceKit.ActionBarControlIdentifier")))
        let abis = try Dictionary(
            uniqueKeysWithValues: [controlType, identifierType]
                .map { ($0, try NativeType.opaque(named: $0.name)) })
        let readIdentifier = try await controlType.resolve(
            .swift(
                .getter(
                    "id", as: (() -> NativeSwiftValue).self,
                    valueABIs: abis, receiverABI: .opaque(named: controlType.name))))
        let readName = try await identifierType.resolve(
            .swift(
                .getter(
                    "id", as: (() -> String).self,
                    receiverABI: .opaque(named: identifierType.name))))
        let anyView = try await runtime.resolve(.swift(.type("SwiftUI.AnyView")))
        // The SDK declares AnyView @frozen with one class-reference field.
        let readView = try await controlType.resolve(
            .swift(
                .getter(
                    "view", as: (() -> NativeSwiftValue).self,
                    valueABIs: [
                        anyView: try .structure(named: anyView.name, fields: [.pointer]),
                        controlType: try .opaque(named: controlType.name),
                    ], receiverABI: .opaque(named: controlType.name))))
        self.shared = shared
        self.providers = providers
        self.readIdentifier = readIdentifier
        self.readName = readName
        self.readView = readView
    }

    @MainActor func providers(in plugins: NativeSwiftValue) throws -> [Any] {
        let owner = try unsafe providers.unsafeInvoke(on: plugins)
        return try owner.withCopy { raw in
            guard let sequence = raw as? any Sequence else {
                throw RemoteScreenError.unavailable(
                    "native-action-providers", "DeviceKit’s action providers are unavailable.")
            }
            func elements<S: Sequence>(_ sequence: S) -> [Any] { sequence.map { $0 } }
            return elements(sequence)
        }
    }

    @MainActor func controls(
        of value: Any, for device: UUID, onError: @escaping @MainActor @Sendable (any Error) -> Void
    )
        async throws -> @MainActor () throws -> [NativeSwiftValue]
    {
        let runtime = ABIRuntime.shared
        func copy<V>(_ value: V) async throws -> NativeSwiftValue { try await Self.bridge(value, runtime: runtime) }
        let provider = try await _openExistential(value, do: copy).copyUnderlyingValue()
        typealias Failure = NativeSwiftClosure<@MainActor @Sendable (any Error) -> Void>
        let failure = try await copy(onError).copyClosure(as: (@MainActor @Sendable (any Error) -> Void).self)
        let read = try await provider.type.resolve(
            .swift(
                .method(
                    "DeviceKit.ActionBarControlProvider.controls(deviceID:onError:)",
                    as: ((UUID, Failure) -> [NativeSwiftValue]).self)))
        return { try unsafe read.unsafeInvoke(on: provider, device, failure) }
    }

    @MainActor func name(of item: NativeSwiftValue) throws -> String {
        try unsafe readName.unsafeInvoke(on: readIdentifier.unsafeInvoke(on: item))
    }

    @MainActor func view(of item: NativeSwiftValue) throws -> AnyView {
        let view = try unsafe readView.unsafeInvoke(on: item)
        return try view.withCopy {
            guard let content = $0 as? AnyView else {
                throw RemoteScreenError.unavailable(
                    "native-action-view", "DeviceKit’s action control is not a SwiftUI view.")
            }
            return content
        }
    }

    @MainActor private static func bridge<Value>(_ value: Value, runtime: ABIRuntime) async throws -> NativeSwiftValue {
        let array = try await runtime.resolve(.swift(.type("Swift.Array", genericArguments: [.type(Value.self)])))
        let read = try await array.resolve(
            .swift(
                .getter(
                    "Swift.Array.subscript.getter : (Swift.Int) -> A",
                    as: ((Int) -> NativeSwiftValue).self)))
        return try unsafe read.unsafeInvoke(on: [value], 0)
    }
}
