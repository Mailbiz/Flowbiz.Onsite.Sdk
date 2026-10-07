import Foundation

// Web getRecoveryDataFromQuery: `_mb_cr_` is base64 of `{t, u, c, its: [[qty, product_id, sku, props?]]}`.
enum RecoveryLinkParser {

    private static let param = "_mb_cr_"
    private static let utmParam = "utm_source"

    static func parse(_ url: String?, expectedAppId: String? = nil) -> RecoveryPayload? {
        guard let url else { return nil }
        let pairs = queryPairs(UtmLinkParser.href(url))
        guard let raw = pairs.first(where: { $0.key == param && !$0.value.isEmpty })?.value else { return nil }
        guard let utm = pairs.first(where: { $0.key == utmParam })?.value, isValidUtm(utm) else { return nil }
        var candidates: [String] = []
        var seen = Set<String>()
        func add(_ candidate: String) {
            if seen.insert(candidate).inserted { candidates.append(candidate) }
        }
        add(raw.replacingOccurrences(of: " ", with: "+"))
        add(raw)
        if let decoded = percentDecode(raw) {
            add(decoded.replacingOccurrences(of: " ", with: "+"))
            add(decoded)
        }
        for candidate in candidates {
            guard let json = decodeBase64(candidate), let payload = mapHash(json, expectedAppId: expectedAppId) else { continue }
            return payload
        }
        return nil
    }

    // Fragment cut first (`#/cart?_mb_cr_=…` holds no query); values stay raw for the base64 candidates.
    private static func queryPairs(_ url: String) -> [(key: String, value: String)] {
        var beforeFragment = Substring(url)
        if let fragmentStart = url.firstIndex(of: "#") { beforeFragment = url[..<fragmentStart] }
        guard let queryStart = beforeFragment.firstIndex(of: "?") else { return [] }
        let query = beforeFragment[beforeFragment.index(after: queryStart)...]
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            if let eq = pair.firstIndex(of: "=") {
                let key = String(pair[..<eq])
                return (percentDecode(key) ?? key, String(pair[pair.index(after: eq)...]))
            }
            return (percentDecode(String(pair)) ?? String(pair), "")
        }
    }

    // Web isValidUtm, "mailbiz" included.
    private static func isValidUtm(_ raw: String) -> Bool {
        let value = (percentDecode(raw) ?? raw).lowercased()
        return value.contains("mailbiz") || value.contains("flowbiz")
    }

    private static func percentDecode(_ value: String) -> String? {
        guard value.contains("%") else { return value }
        return value.removingPercentEncoding
    }

    private static func decodeBase64(_ value: String) -> String? {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func mapHash(_ json: String, expectedAppId: String?) -> RecoveryPayload? {
        guard
            let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
            let hash = root as? [String: Any],
            let cartId = nonEmptyString(hash["c"]),
            let userId = nonEmptyString(hash["u"]),
            let tenant = nonEmptyString(hash["t"]),
            let its = hash["its"] as? [Any],
            !its.isEmpty
        else { return nil }

        if let expectedAppId, tenant != expectedAppId {
            SdkLog.debug("recovery link ignored: tenant mismatch")
            return nil
        }

        var products = [RecoveryProduct]()
        products.reserveCapacity(its.count)
        for element in its {
            guard let item = element as? [Any] else { continue }
            products.append(RecoveryProduct(
                productId: itemString(item, 1),
                sku: itemString(item, 2),
                quantity: webQuantity(item.count > 0 ? item[0] : nil),
                recoveryProperties: recoveryProperties(item.count > 3 ? item[3] : nil)
            ))
        }
        guard !products.isEmpty else { return nil }
        return RecoveryPayload(cartId: cartId, userId: userId, products: products)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let number as NSNumber:
            // The web passes a numeric id through untouched; stringified here to fit the typed payload.
            return JSONValue.isBoolean(number) ? (number.boolValue ? "true" : "false") : number.stringValue
        default:
            return nil
        }
    }

    private static func itemString(_ item: [Any], _ index: Int) -> String {
        guard index < item.count else { return "" }
        switch item[index] {
        case let string as String:
            return string
        case let number as NSNumber:
            return JSONValue.isBoolean(number) ? (number.boolValue ? "true" : "false") : number.stringValue
        default:
            return ""
        }
    }

    // Web `parseInt(it[0]) || 1`: JS parseInt semantics, and NaN *and* 0 become 1.
    private static func webQuantity(_ value: Any?) -> Int {
        let parsed: Int?
        switch value {
        case let number as NSNumber where !JSONValue.isBoolean(number):
            let double = number.doubleValue
            if double.isNaN {
                parsed = nil
            } else {
                // Clamped: Int(double) traps out of range; Int32 bounds match Kotlin's saturating toInt().
                let truncated = double.rounded(.towardZero)
                let clamped = min(max(truncated, Double(Int32.min)), Double(Int32.max))
                parsed = Int(clamped)
            }
        case let string as String:
            parsed = parseIntLeading(string)
        default:
            parsed = nil
        }
        guard let parsed, parsed != 0 else { return 1 }
        return parsed
    }

    private static func parseIntLeading(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var units = Array(trimmed.utf16)[...]
        var sign: Int64 = 1
        if let head = units.first, head == UInt16(UnicodeScalar("+").value) || head == UInt16(UnicodeScalar("-").value) {
            if head == UInt16(UnicodeScalar("-").value) { sign = -1 }
            units = units.dropFirst()
        }
        let zero = UInt16(UnicodeScalar("0").value)
        let nine = UInt16(UnicodeScalar("9").value)
        var digits = 0
        var accumulated: Int64 = 0
        for unit in units {
            guard unit >= zero, unit <= nine else { break }
            if digits < 12 { // beyond any realistic quantity; avoids overflow
                accumulated = accumulated * 10 + Int64(unit - zero)
            }
            digits += 1
        }
        guard digits > 0 else { return nil }
        return Int(min(max(sign * accumulated, Int64(Int32.min)), Int64(Int32.max)))
    }

    // Web tryToParseJson of a JSON-object string; a nested object is tolerated, garbage is nil (web `{}`).
    private static func recoveryProperties(_ value: Any?) -> [String: JSONValue]? {
        switch value {
        case let string as String:
            guard
                !string.isEmpty,
                let root = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
                let object = root as? [String: Any]
            else { return nil }
            return JSONValue.objectFromFoundation(object)
        case let object as [String: Any]:
            return JSONValue.objectFromFoundation(object)
        default:
            return nil
        }
    }
}
