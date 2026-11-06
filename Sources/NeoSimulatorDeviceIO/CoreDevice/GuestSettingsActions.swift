import ABIBridge
import Foundation
import XPC

/// Uses the installed action declarations and codecs to reach each guest provider.
@MainActor
package final class GuestSettingsActions {
    private let guest: SimulatorGuestHID
    private let identifier: String
    private var bindings: [String: Binding] = [:]
    private var connections: [String: GuestHIDConnection] = [:]

    package init(guest: SimulatorGuestHID, identifier: String) {
        self.guest = guest
        self.identifier = identifier
    }

    package func get(_ declaration: String) async throws -> DeviceInspectorValue {
        try await perform(declaration, input: [:], readsOutput: true)
    }

    package func set(_ declaration: String, input: [String: Any]) async throws {
        _ = try await perform(declaration, input: input, readsOutput: false)
    }

    /// Applies the filter of a `DeviceColorFilter.FilterType` member, or no filter. The provider rejects intensity for
    /// grayscale and disabled filters.
    package func setColorFilter(named member: String?, takesIntensity: Bool, intensity: Double?) async throws {
        var filter: [String: Any] = ["enabled": member != nil]
        if let member {
            filter["filterType"] = try await namedValue("DeviceColorFilter.FilterType", member: member)
            if takesIntensity {
                let level = if let intensity { intensity }
                    else { try await get("GetColorFilterActionDeclaration")["colorFilter"]?["intensity"]?.numeric }
                if let level { filter["intensity"] = level }
            }
        }
        try await set("SetColorFilterActionDeclaration", input: ["colorFilter": filter])
    }

    private func encoded(_ value: NativeSwiftValue) throws -> Data {
        try value.withCopy {
            guard let encodable = $0 as? any Encodable else {
                throw DeviceIOError.unavailable("guest-settings-value", "The native setting cannot be encoded.")
            }
            return try JSONEncoder().encode(encodable)
        }
    }

    package func namedValue(_ typeName: String, member: String) async throws -> Any {
        let type = try await ABIRuntime.shared.resolve(.swift(.type("CoreDeviceUtilities." + typeName)))
        // These CoreDevice value getters return through Swift's indirect result buffer.
        let getter = try await type.resolve(.swift(.staticGetter(member, as: (() -> NativeSwiftValue).self,
            valueABIs: [type: try .opaque(named: type.name)])))
        return try unsafe JSONSerialization.jsonObject(with: encoded(getter.unsafeInvoke()))
    }

    private func perform(_ declaration: String, input: [String: Any], readsOutput: Bool) async throws -> DeviceInspectorValue {
        let binding: Binding
        if let existing = bindings[declaration] { binding = existing }
        else {
            binding = try await Binding(declaration: declaration, readsOutput: readsOutput)
            bindings[declaration] = binding
        }
        let connection: GuestHIDConnection
        if let existing = connections[binding.feature] { connection = existing }
        else {
            connection = try await guest.connection(to: binding.feature)
            connections[binding.feature] = connection
        }
        let message = try binding.message(identifier: identifier, input: JSONSerialization.data(withJSONObject: input))
        let reply = try await connection.request(message, timeout: .seconds(10), cancelsWithTask: true)
        return try binding.output(reply)
    }

    private struct Binding {
        let feature: String
        let action: String
        let encodeInput: (Data) throws -> xpc_object_t
        let decodeOutput: ((xpc_object_t) throws -> DeviceInspectorValue)?

        init(declaration: String, readsOutput: Bool) async throws {
            let runtime = ABIRuntime.shared
            let name = "CoreDeviceUtilities." + declaration
            let type = try await runtime.resolve(.swift(.type(name)))
            action = try await unsafe type.resolve(.swift(.staticGetter("identifier", as: (() -> String).self))).unsafeInvoke()
            let location = try await unsafe type.resolve(.swift(.staticGetter("executionLocation", as: (() -> NativeSwiftValue).self))).unsafeInvoke()
            guard let payload = try await location.copyEnumPayload(forCase: "remoteDevice"),
                  let feature = try payload.withCopy({ $0 as? String }) else {
                throw DeviceIOError.unavailable("guest-settings-action", "The setting is not provided by a guest service.")
            }
            self.feature = feature
            let inputType = try await runtime.resolve(.swift(.type(name + ".Input")))
            let jsonDecoder = try await runtime.resolve(.swift(.type(String(reflecting: JSONDecoder.self))))
            let data = try await runtime.resolve(.swift(.type("Foundation.Data")))
            let decodeJSON = try await jsonDecoder.resolve(.swift(.method("decode(_:from:)",
                as: ((NativeSwiftValue, Data) throws -> NativeSwiftValue).self, genericArguments: [.type(inputType)],
                valueABIs: [data: try .structure(named: data.name, fields: [.uint64, .uint64])])))
            let inputMetatype = try inputType.makeMetatypeValue()
            let xpcEncoder = try await runtime.resolve(.swift(.type("Mercury.XPCObjectEncoder")))
            let makeEncoder = try await xpcEncoder.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self)))
            let encode = try await xpcEncoder.resolve(.swift(.method(
                "Mercury.XPCObjectEncoder.encode<A where A: Swift.Encodable>(A) throws -> __C.OS_xpc_object",
                as: ((NativeSwiftValue) throws -> xpc_object_t).self, genericArguments: [.type(inputType)])))
            encodeInput = { data in
                let value = try unsafe decodeJSON.unsafeInvoke(on: JSONDecoder(), inputMetatype, data)
                return try unsafe encode.unsafeInvoke(on: makeEncoder.unsafeInvoke(), value)
            }
            if readsOutput {
                let outputType = try await runtime.resolve(.swift(.type(name + ".Output")))
                let xpcDecoder = try await runtime.resolve(.swift(.type("Mercury.XPCObjectDecoder")))
                let makeDecoder = try await xpcDecoder.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self)))
                let decode = try await xpcDecoder.resolve(.swift(.method(
                    "Mercury.XPCObjectDecoder.decode<A where A: Swift.Decodable>(_: A.Type, from: __C.OS_xpc_object) throws -> A",
                    as: ((NativeSwiftValue, xpc_object_t) throws -> NativeSwiftValue).self, genericArguments: [.type(outputType)])))
                let metatype = try outputType.makeMetatypeValue()
                decodeOutput = { object in
                    let value = try unsafe decode.unsafeInvoke(on: makeDecoder.unsafeInvoke(), metatype, object)
                    let data = try value.withCopy { value in
                        guard let encodable = value as? any Encodable else {
                            throw DeviceIOError.unavailable("guest-settings-output", "The setting's reply cannot be encoded.")
                        }
                        return try JSONEncoder().encode(encodable)
                    }
                    return try JSONDecoder().decode(DeviceInspectorValue.self, from: data)
                }
            } else { decodeOutput = nil }
        }

        func message(identifier: String, input: Data) throws -> xpc_object_t {
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(message, "CoreDevice.actionIdentifier", action)
            xpc_dictionary_set_string(message, "CoreDevice.deviceIdentifier", identifier)
            xpc_dictionary_set_string(message, "CoreDevice.invocationIdentifier", UUID().uuidString)
            xpc_dictionary_set_int64(message, "CoreDevice.CoreDeviceDDIProtocolVersion", 1)
            guard let version = Bundle(path: "/Library/Developer/PrivateFrameworks/CoreDevice.framework")?
                .object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
                throw DeviceIOError.unavailable("coredevice-version", "CoreDevice's version is unavailable.")
            }
            let parts = version.split(separator: ".").compactMap { UInt64($0) }
            let versionValue = xpc_dictionary_create(nil, nil, 0)
            let components = xpc_array_create(nil, 0)
            for part in parts { xpc_array_append_value(components, xpc_uint64_create(part)) }
            xpc_dictionary_set_value(versionValue, "components", components)
            xpc_dictionary_set_int64(versionValue, "originalComponentsCount", Int64(parts.count))
            xpc_dictionary_set_string(versionValue, "stringValue", version)
            xpc_dictionary_set_value(message, "CoreDevice.coreDeviceVersion", versionValue)
            xpc_dictionary_set_value(message, "CoreDevice.input", try encodeInput(input))
            return message
        }

        func output(_ reply: xpc_object_t) throws -> DeviceInspectorValue {
            if let error = xpc_dictionary_get_value(reply, "CoreDevice.error") {
                let domain = xpc_dictionary_get_string(error, "domain").map { String(cString: $0) } ?? "CoreDevice"
                let code = xpc_dictionary_get_int64(error, "code")
                var info: [String: Any] = [:]
                if let properties = xpc_dictionary_get_value(error, "userInfo"),
                   let description = xpc_dictionary_get_string(properties, NSLocalizedDescriptionKey) {
                    info[NSLocalizedDescriptionKey] = String(cString: description)
                }
                let description = xpc_copy_description(error)
                info[NSDebugDescriptionErrorKey] = String(cString: description)
                free(description)
                throw NSError(domain: domain, code: Int(code), userInfo: info)
            }
            guard let output = xpc_dictionary_get_value(reply, "CoreDevice.output") else {
                throw DeviceIOError.io("guest-settings-reply", "The guest omitted the setting's reply.")
            }
            return try decodeOutput?(output) ?? .object([:])
        }
    }
}
