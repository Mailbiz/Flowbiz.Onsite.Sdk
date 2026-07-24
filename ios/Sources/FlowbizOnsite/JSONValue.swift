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
