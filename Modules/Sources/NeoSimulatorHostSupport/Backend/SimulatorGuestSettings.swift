import ABIBridge
import Foundation
import NeoSimulatorKit
import XPC

/// Settings of the simulator that owns the selected screen, independent of CoreDevice discovery.
@MainActor
package final class SimulatorGuestSettings {
    private let source: SimulatorHostDevice
    private let xcodeURL: URL
    private var devicePreparation: Task<SimulatorDevice, any Error>?
    private var actionPreparation: Task<GuestSettingsActions, any Error>?

    nonisolated package init(device: SimulatorHostDevice, xcodeURL: URL) {
        source = device
        self.xcodeURL = xcodeURL
    }

    private func selectedDevice() async throws -> SimulatorDevice {
        if let devicePreparation { return try await devicePreparation.value }
        let preparation = Task { [source, xcodeURL] in
            try CoreDeviceRemoteScreenDevice.load("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator")
            let interface = try await CoreSimulatorInterface(runtime: .shared)
            let set = try SimulatorDeviceSet(interface: interface,
                developerDirectory: xcodeURL.appendingPathComponent("Contents/Developer").path, path: source.deviceSetPath)
            guard let device = try set.device(withIdentifier: source.identifier) else {
                throw CLIError.unavailable("simulator-settings-device", "The selected simulator is no longer available.")
            }
            return device
        }
        devicePreparation = preparation
        return try await preparation.value
    }

    package func execute(_ arguments: [String]) async throws -> Data {
        guard arguments.count == 3 else { throw CLIError.configuration("guest-settings-operation", "Expected a simulator settings operation.") }
        switch arguments[1] {
        case "read":
            guard let query = SimulatorSettingsBackend.Query(rawValue: arguments[2]) else {
                throw CLIError.configuration("guest-settings-operation", "Unknown simulator settings query.")
            }
            return try JSONEncoder().encode(await read(query, device: selectedDevice()))
        case "set":
            try await set(JSONDecoder().decode(SimulatorDeviceSetting.self, from: Data(arguments[2].utf8)), device: selectedDevice())
            return Data()
        default: throw CLIError.configuration("guest-settings-operation", "Unknown simulator settings operation.")
        }
    }

    private func service(device: SimulatorDevice) async throws -> GuestSettingsActions {
        if let actionPreparation { return try await actionPreparation.value }
        let preparation = Task { [device] in
            try await GuestSettingsActions(guest: SimulatorGuestHID(lookUp: device.lookUp), identifier: device.identifier)
        }
        actionPreparation = preparation
        return try await preparation.value
    }

    private func read(_ query: SimulatorSettingsBackend.Query, device: SimulatorDevice) async -> SimulatorDeviceSettings {
        var result = SimulatorDeviceSettings()
        func capture<T>(_ name: String, _ read: () async throws -> T) async -> T? {
            guard !Task.isCancelled else { return nil }
            do { return try await read() }
            catch {
                if !Task.isCancelled { result.issues.append("\(name): \(error.localizedDescription)") }
                return nil
            }
        }
        func get(_ declaration: String) async throws -> DeviceInspectorValue {
            try await service(device: device).get(declaration)
        }
        switch query {
        case .simulatorContentSize:
            result.contentSize = await capture("content_size") {
                let category = try device.contentSizeCategory()
                guard (1...SimulatorDeviceSettings.contentSizes.count).contains(category) else {
                    throw CLIError.unavailable("content-size", "The simulator returned an unknown text size: \(category).")
                }
                return SimulatorDeviceSettings.contentSizes[category - 1]
            }
        case .appearance:
            result.lookAndFeel = await capture("look and feel") {
                try await get("GetDeviceLookAndFeelActionDeclaration")["lookAndFeel"]?["name"]?.string
            } ?? nil
            if let supported = await capture("supported looks and feels", {
                let values = try await get("GetSupportedLooksAndFeelsActionDeclaration")["looksAndFeels"]?.array ?? []
                var supported: [SimulatorLookAndFeel] = []
                for choice in SimulatorLookAndFeel.allCases {
                    let native = try await service(device: device).namedValue("DeviceLookAndFeel", member: choice.nativeMember)
                    if values.contains(try DeviceInspectorValue.propertyList(native)) { supported.append(choice) }
                }
                return supported
            }) {
                result.supportedLooksAndFeels = supported
            }
            result.liquidGlassOpacity = await capture("Liquid Glass") {
                try await get("GetLiquidGlassConfigurationActionDeclaration")["configuration"]?["opacity"]?.numeric
            } ?? nil
            if let filter = await capture("color filter", { try await get("GetColorFilterActionDeclaration")["colorFilter"] }) {
                if filter?["enabled"]?.boolean == false { result.colorFilter = SimulatorColorFilter.none }
                else if let name = filter?["filterType"]?["name"]?.string {
                    result.colorFilter = SimulatorColorFilter(rawValue: name.lowercased())
                }
                if filter?["enabled"]?.boolean == true, result.colorFilter == nil {
                    result.issues.append("color filter: The device returned an unrecognized enabled color filter.")
                }
                result.colorFilterIntensity = filter?["intensity"]?.numeric
            }
            result.reduceMotion = await capture("Reduce Motion") {
                try await get("GetReduceMotionActionDeclaration")["reduceMotion"]?["enabled"]?.boolean
            } ?? nil
            result.showBorders = await capture("Show Borders") {
                try await get("GetShowBordersActionDeclaration")["showBorders"]?["enabled"]?.boolean
            } ?? nil
            result.reduceTransparency = await capture("Reduce Transparency") {
                try await get("GetReduceTransparencyActionDeclaration")["reduceTransparency"]?["enabled"]?.boolean
            } ?? nil
        case .voiceOver:
            result.voiceOver = await capture("VoiceOver") {
                try await get("GetVoiceOverActionDeclaration")["voiceOverConfiguration"]?["enabled"]?.boolean
            } ?? nil
        case .audio:
            result.volume = await capture("volume") {
                let volume = try device.notificationState("com.apple.springboard.volumestate")
                guard volume <= 100 else {
                    throw CLIError.io("audio-volume", "The simulator returned a volume outside 0...100.")
                }
                return Int(volume)
            }
            if let state = await capture("audio routes", {
                let audio = try await SimulatorAudioInterface(runtime: .shared)
                let connection = try audio.connect(to: device, changed: { _ in })
                defer { connection.disconnect() }
                return try connection.state()
            }) {
                func selection(_ value: String?) -> String? { value == AudioRouting.systemDefault ? "systemDefault" : value }
                result.audioInputDevice = selection(state.inputRoute)
                result.audioOutputDevice = selection(state.outputRoute)
                result.audioInputDevices = state.devices(in: .input).map { SimulatorAudioDevice(identifier: $0.uid, name: $0.name) }
                result.audioOutputDevices = state.devices(in: .output).map { SimulatorAudioDevice(identifier: $0.uid, name: $0.name) }
            }
        default:
            result.issues.append("settings: This query uses the simulator command-line tools.")
        }
        return result
    }

    private func set(_ setting: SimulatorDeviceSetting, device: SimulatorDevice) async throws {
        func change(_ declaration: String, _ input: [String: Any]) async throws {
            try await service(device: device).set(declaration, input: input)
        }
        switch setting {
        case .contentSize(let value):
            guard let index = SimulatorDeviceSettings.contentSizes.firstIndex(of: value) else {
                throw CLIError.configuration("guest-settings-operation", "Unknown text size: \(value).")
            }
            try device.setContentSizeCategory(index + 1)
        case .lookAndFeel(let value):
            let native = try await service(device: device).namedValue("DeviceLookAndFeel",
                member: value.nativeMember)
            try await change("SetDeviceLookAndFeelActionDeclaration", ["lookAndFeel": native])
        case .liquidGlassOpacity(let value):
            try await change("SetLiquidGlassConfigurationActionDeclaration", ["configuration": ["opacity": value]])
        case .colorFilter(let value, let intensity):
            let current = try await service(device: device).get("GetColorFilterActionDeclaration")["colorFilter"]
            var filter: [String: Any] = ["enabled": value != .none]
            if value != .none {
                filter["filterType"] = try await service(device: device).namedValue("DeviceColorFilter.FilterType", member: value.rawValue)
            } else if let name = current?["filterType"]?["name"]?.string {
                filter["filterType"] = ["name": name]
            }
            if let intensity = intensity ?? current?["intensity"]?.numeric { filter["intensity"] = intensity }
            try await change("SetColorFilterActionDeclaration", ["colorFilter": filter])
        case .reduceMotion(let value):
            try await change("SetReduceMotionActionDeclaration", ["reduceMotion": ["enabled": value]])
        case .showBorders(let value):
            try await change("SetShowBordersActionDeclaration", ["showBorders": ["enabled": value]])
        case .reduceTransparency(let value):
            try await change("SetReduceTransparencyActionDeclaration", ["reduceTransparency": ["enabled": value]])
        case .voiceOver(let value):
            try await change("SetVoiceOverActionDeclaration", ["voiceOverConfiguration": ["enabled": value]])
        case .volume(let value):
            guard (0...100).contains(value) else { throw CLIError.configuration("guest-settings-operation", "Volume must be between 0 and 100.") }
            try await device.setNotificationState("com.apple.springboard.volumestate", to: UInt64(value))
            try await device.postNotification("com.apple.springboard.volumestate")
        case .audioInputDevice(let value), .audioOutputDevice(let value):
            let audio = try await SimulatorAudioInterface(runtime: .shared)
            let connection = try audio.connect(to: device, changed: { _ in })
            defer { connection.disconnect() }
            let scope: AudioScope = if case .audioInputDevice = setting { .input } else { .output }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                do {
                    try connection.route(scope, to: value == "systemDefault" ? AudioRouting.systemDefault : value) { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        default: throw CLIError.configuration("guest-settings-operation", "This setting uses the simulator command-line tools.")
        }
    }

}

private extension SimulatorLookAndFeel {
    var nativeMember: String {
        switch self { case .clear: "clearLiquidGlass"; case .tinted: "tintedLiquidGlass" }
    }
}

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

    private func encoded(_ value: NativeSwiftValue) throws -> Data {
        try value.withCopy {
            guard let encodable = $0 as? any Encodable else {
                throw CLIError.unavailable("guest-settings-value", "The native setting cannot be encoded.")
            }
            return try JSONEncoder().encode(encodable)
        }
    }

    package func namedValue(_ typeName: String, member: String) async throws -> Any {
        let type = try await ABIRuntime.shared.resolve(.swift(.type("CoreDeviceUtilities." + typeName)))
        let getter = try await type.resolve(.swift(.staticGetter(member, as: (() -> NativeSwiftValue).self)))
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
            connection = try guest.connection(to: binding.feature)
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
                throw CLIError.unavailable("guest-settings-action", "The setting is not provided by a guest service.")
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
                            throw CLIError.unavailable("guest-settings-output", "The setting's reply cannot be encoded.")
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
                throw CLIError.unavailable("coredevice-version", "CoreDevice's version is unavailable.")
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
                throw CLIError.io("guest-settings-reply", "The guest omitted the setting's reply.")
            }
            return try decodeOutput?(output) ?? .object([:])
        }
    }
}

private extension DeviceInspectorValue {
    var numeric: Double? {
        switch self {
        case .number(let value): value
        case .integer(let value): Double(value)
        case .unsignedInteger(let value): Double(value)
        default: nil
        }
    }
}
