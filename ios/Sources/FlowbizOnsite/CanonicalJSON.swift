import Foundation

/// Canonical JSON writer for the wire `data` payload strings (SPEC §4/§5).
///
/// `JSONSerialization` renders doubles with up-to-17-digit decimal expansions
/// (`19.99` → `19.989999999999998`, `0.1` → `0.10000000000000001`) and escapes
/// forward slashes (`\/`); Android's org.json and the web tracker's
/// `JSON.stringify` do neither, so the produced wire strings diverge
/// byte-for-byte. This writer emits the canonical cross-platform form —
/// pinned to web `JSON.stringify` (the reference implementation):
///
/// - **numbers**: shortest round-trip digits, formatted with the ECMAScript
///   `Number::toString` layout rules — `19.99`, `0.1`, whole doubles without
///   a fraction part (`19.0` → `19`), fixed notation up to 21 digits
///   (`10000000`, not `1.0E7`), exponent form beyond (`1e+21`), `-0.0` → `0`
/// - **strings**: minimal escaping — only `"` `\` and control characters;
///   raw slashes, raw unicode
/// - **objects**: keys sorted by UTF-16 code units (deterministic output;
///   matches Kotlin `sorted()` and JS `Array.prototype.sort`)
///
/// Mirrored by the Kotlin `CanonicalJson`; both are pinned byte-for-byte by
/// `expected.data_canonical` in `shared/fixtures/`.
///
/// **Throws** on non-finite numbers (NaN/±Infinity) — the same contract as
/// the Kotlin serializer (org.json rejects non-finite doubles at tree-build
/// time). The SPEC §3 never-throw guarantee is applied at the public API
/// boundary (Slice 4), not here.
enum CanonicalJSON {

    struct WriteError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Renders a JSON tree (`String` / `NSNumber` / `Bool` / `Int` / `Double`
    /// / `NSNull` / `[Any]` / `[String: Any]`) as a compact canonical string.
    static func render(_ value: Any) throws -> String {
        var out = ""
        try write(value, into: &out)
        return out
    }

    private static func write(_ value: Any, into out: inout String) throws {
        switch value {
        case let string as String:
            writeString(string, into: &out)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                out += number.boolValue ? "true" : "false"
            } else {
                out += try numberToken(number)
            }
        case is NSNull:
            out += "null"
        case let object as [String: Any]:
            out += "{"
            let keys = object.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                try write(object[key]!, into: &out)
            }
            out += "}"
        case let array as [Any]:
            out += "["
            for (index, element) in array.enumerated() {
                if index > 0 { out += "," }
                try write(element, into: &out)
            }
            out += "]"
        default:
            throw WriteError("unsupported JSON value of type \(type(of: value))")
        }
    }

    // MARK: - Strings

    /// Minimal escaping, matching `JSON.stringify`: `"` and `\` plus control
    /// characters; everything else (slashes, unicode) is emitted raw.
    private static func writeString(_ string: String, into out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{09}": out += "\\t"
            case "\u{0A}": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\u{0D}": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: - Numbers

    private static func numberToken(_ number: NSNumber) throws -> String {
        switch String(cString: number.objCType) {
        case "f", "d":
            return try doubleToken(number.doubleValue)
        case "Q":
            return "\(number.uint64Value)"
        default:
            return "\(number.int64Value)"
        }
    }

    /// ECMAScript `Number::toString(10)` rendering of a finite double, built
    /// from Swift's shortest-round-trip `"\(Double)"` digits.
    static func doubleToken(_ value: Double) throws -> String {
        guard value.isFinite else {
            throw WriteError("JSON does not allow non-finite numbers (\(value))")
        }
        if value == 0 { return "0" } // covers -0.0 → "0" (JSON.stringify(-0))

        // Parse the shortest representation, e.g. "19.99", "10000000.0",
        // "1e+21", "1e-07", into sign + digit string + decimal exponent.
        var repr = Substring("\(value)")
        var sign = ""
        if repr.first == "-" {
            sign = "-"
            repr = repr.dropFirst()
        }
        var mantissa = repr
        var exp10 = 0
        if let eIndex = repr.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = repr[..<eIndex]
            exp10 = Int(repr[repr.index(after: eIndex)...]) ?? 0
        }
        var digits: [Character]
        var pointPosition: Int
        if let dotIndex = mantissa.firstIndex(of: ".") {
            digits = Array(mantissa[..<dotIndex]) + Array(mantissa[mantissa.index(after: dotIndex)...])
            pointPosition = mantissa.distance(from: mantissa.startIndex, to: dotIndex)
        } else {
            digits = Array(mantissa)
            pointPosition = digits.count
        }
        // `n` per ECMA-262 Number::toString: value == 0.digits × 10^n.
        var n = pointPosition + exp10
        var start = 0
        while start < digits.count - 1 && digits[start] == "0" {
            start += 1
            n -= 1
        }
        digits.removeFirst(start)
        while digits.count > 1 && digits.last == "0" {
            digits.removeLast()
        }
        let k = digits.count
        let digitString = String(digits)

        if k <= n && n <= 21 {
            return sign + digitString + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            let split = digitString.index(digitString.startIndex, offsetBy: n)
            return sign + digitString[..<split] + "." + digitString[split...]
        }
        if -6 < n && n <= 0 {
            return sign + "0." + String(repeating: "0", count: -n) + digitString
        }
        let exponent = n - 1
        let head = k == 1 ? digitString : "\(digitString.first!)." + digitString.dropFirst()
        return sign + head + "e" + (exponent >= 0 ? "+" : "-") + String(abs(exponent))
    }
}
