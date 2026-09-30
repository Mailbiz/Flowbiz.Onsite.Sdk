import Foundation

/// Free-form `properties` values, from literals; keys ship as-is, `.null` object entries are dropped.
public enum JSONValue: Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension JSONValue {
    static func fromFoundation(_ any: Any) -> JSONValue? {
        switch any {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            return isBoolean(number) ? .bool(number.boolValue) : .number(number.doubleValue)
        case is NSNull:
            return .null
        case let array as [Any]:
            var elements = [JSONValue]()
            elements.reserveCapacity(array.count)
            for element in array {
                guard let value = fromFoundation(element) else { return nil }
                elements.append(value)
            }
            return .array(elements)
        case let object as [String: Any]:
            var entries = [String: JSONValue](minimumCapacity: object.count)
            for (key, value) in object {
                guard let converted = fromFoundation(value) else { return nil }
                entries[key] = converted
            }
            return .object(entries)
        default:
            return nil
        }
    }

    static func objectFromFoundation(_ object: [String: Any]) -> [String: JSONValue]? {
        guard case .object(let entries)? = fromFoundation(object) else { return nil }
        return entries
    }

    // Not `as? Bool`, which also matches a numeric 0 or 1: only a CFBoolean is a JSON boolean.
    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    var foundationValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded() == value, let integer = Int64(exactly: value) {
                return NSNumber(value: integer)
            }
            return NSNumber(value: value)
        case .bool(let value):
            return NSNumber(value: value)
        case .null:
            return NSNull()
        case .array(let elements):
            return elements.map { $0.foundationValue }
        case .object(let entries):
            var result = [String: Any](minimumCapacity: entries.count)
            for (key, value) in entries where value != .null {
                result[key] = value.foundationValue
            }
            return result
        }
    }
}
