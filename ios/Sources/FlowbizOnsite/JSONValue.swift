import Foundation

/// A `Sendable` JSON value, used for the free-form `properties` /
/// `recoveryProperties` payload fields (SPEC §5).
///
/// `[String: Any]` cannot conform to `Sendable` (SPEC §3 requires all public
/// event types to be Sendable value types), so free-form maps are typed as
/// `[String: JSONValue]`. The literal conformances keep construction
/// ergonomic — this reads like a plain dictionary literal:
///
/// ```swift
/// properties: ["cor": "Azul Marinho", "tamanho": "P", "estoque": 12, "ativo": true]
/// ```
///
/// The Kotlin SDK keeps `Map<String, Any?>` for the same fields; both
/// serialize identically (pinned by `shared/fixtures/`).
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
    /// `JSONSerialization` output → `JSONValue`, for the maps *returned to*
    /// the host by `handlePush`/`handleLink` (the inverse direction of
    /// `foundationValue`). Values outside the JSON model return nil — which
    /// cannot happen for genuine `JSONSerialization` output.
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

    /// `[String: Any]` (JSONSerialization output) → `[String: JSONValue]`;
    /// nil when any value falls outside the JSON model.
    static func objectFromFoundation(_ object: [String: Any]) -> [String: JSONValue]? {
        guard case .object(let entries)? = fromFoundation(object) else { return nil }
        return entries
    }

    /// NSNumber booleans are CFBooleans underneath; a plain number is not.
    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Foundation representation for `JSONSerialization`.
    ///
    /// Matches the Kotlin serializer's rules: `null` entries inside objects
    /// are dropped (nulls never appear on the wire for maps), while `null`
    /// elements inside arrays are kept as JSON `null` to preserve positions.
    /// Whole numbers are emitted as integers (`12`, not `12.0`).
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
