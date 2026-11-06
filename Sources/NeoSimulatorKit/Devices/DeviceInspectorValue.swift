import CoreFoundation
import Foundation

/// A JSON or property-list value exposed by the device's command-line tools.
package indirect enum DeviceInspectorValue: Equatable, Sendable, Decodable {
    case object([String: Self]), array([Self]), string(String), integer(Int64), unsignedInteger(UInt64), number(Double), boolean(Bool), data(Data), date(Date), null

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(UInt64.self) { self = .unsignedInteger(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: Self].self) { self = .object(value) }
        else { self = .array(try container.decode([Self].self)) }
    }

    package var string: String? { if case .string(let value) = self { value } else { nil } }
    package var object: [String: Self]? { if case .object(let value) = self { value } else { nil } }
    package var array: [Self]? { if case .array(let value) = self { value } else { nil } }
    package var boolean: Bool? {
        switch self {
        case .boolean(let value): value
        case .integer(0), .unsignedInteger(0), .string("0"): false
        case .integer(1), .unsignedInteger(1), .string("1"): true
        default: nil
        }
    }
    package subscript(_ key: String) -> Self? { object?[key] }

    package static func propertyList(_ value: Any) throws -> Self {
        switch value {
        case let dictionary as [String: Any]: return .object(try dictionary.mapValues(propertyList))
        case let array as [Any]: return .array(try array.map(propertyList))
        case let string as String: return .string(string)
        case let data as Data: return .data(data)
        case let date as Date: return .date(date)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            let type = String(cString: number.objCType)
            if type == "f" || type == "d" { return .number(number.doubleValue) }
            if type == "Q", number.uint64Value > UInt64(Int64.max) { return .unsignedInteger(number.uint64Value) }
            return .integer(number.int64Value)
        default: throw DeviceInspectorError.invalidResponse("The device returned an unsupported property-list value.")
        }
    }
}
