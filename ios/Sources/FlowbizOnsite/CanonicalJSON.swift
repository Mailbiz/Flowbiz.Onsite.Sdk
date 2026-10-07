import Foundation

// The web's JSON.stringify form; JSONSerialization renders 19.99 as 19.989999999999998 and escapes `/`.
enum CanonicalJSON {

    struct WriteError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func render(_ value: Any) throws -> String {
        var out = ""
        try write(value, into: &out)
        return out
    }

    // Keys in the given order, not sorted: context.utm keeps the web's insertion order.
    static func renderStringPairs(_ pairs: [(key: String, value: String)]) -> String {
        var out = "{"
        for (index, pair) in pairs.enumerated() {
            if index > 0 { out += "," }
            writeString(pair.key, into: &out)
            out += ":"
            writeString(pair.value, into: &out)
        }
        return out + "}"
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
            // UTF-16 code-unit order, like JS sort; String's own < differs.
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

    // As JSON.stringify: only quotes, backslashes and control characters are escaped.
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

    // ECMAScript Number::toString(10), from Swift's shortest-round-trip digits.
    static func doubleToken(_ value: Double) throws -> String {
        guard value.isFinite else {
            throw WriteError("JSON does not allow non-finite numbers (\(value))")
        }
        if value == 0 { return "0" } // covers -0.0 → "0" (JSON.stringify(-0))

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
