import Foundation

/// Pure decoder behind `Flowbiz.handleLink` (SPEC §11): URL string →
/// `_mb_cr_` query value (+ `utm_source` guard) → base64 → hash JSON
/// `{t, u, c, its: [[qty, product_id, sku, recovery_properties?]]}` →
/// `RecoveryPayload`. Mirrors the web tag's `getRecoveryDataFromQuery`.
///
/// Encoding tolerance: the value is tried raw, percent-decoded (`%XX`
/// only), and with `' '` restored to `'+'`; missing base64 padding is
/// added; URL-safe `-`/`_` are accepted. First candidate that decodes to a
/// valid payload wins.
///
/// Tenant check: when `expectedAppId` is given (SDK initialized), `t` must
/// equal it, like web `appId === hash.t`. Before initialize the decoder is
/// pure and skips the check (SPEC §3). Never throws.
enum RecoveryLinkParser {

    private static let param = "_mb_cr_"
    private static let utmParam = "utm_source"

    static func parse(_ url: String?, expectedAppId: String? = nil) -> RecoveryPayload? {
        guard let url else { return nil }
        let pairs = queryPairs(url)
        guard let raw = pairs.first(where: { $0.key == param && !$0.value.isEmpty })?.value else { return nil }
        guard let utm = pairs.first(where: { $0.key == utmParam })?.value, isValidUtm(utm) else { return nil }
        var candidates = [raw]
        if let decoded = percentDecode(raw), decoded != raw { candidates.append(decoded) }
        for candidate in candidates.map({ $0.replacingOccurrences(of: " ", with: "+") }) + candidates {
            guard let json = decodeBase64(candidate), let payload = mapHash(json, expectedAppId: expectedAppId) else { continue }
            return payload
        }
        return nil
    }

    /// Query pairs in order (fragment ignored). Keys are percent-decoded;
    /// values are left raw (callers decide how to decode them).
    private static func queryPairs(_ url: String) -> [(key: String, value: String)] {
        guard let queryStart = url.firstIndex(of: "?") else { return [] }
        var query = url[url.index(after: queryStart)...]
        if let fragmentStart = query.firstIndex(of: "#") { query = query[..<fragmentStart] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            if let eq = pair.firstIndex(of: "=") {
                let key = String(pair[..<eq])
                return (percentDecode(key) ?? key, String(pair[pair.index(after: eq)...]))
            }
            return (percentDecode(String(pair)) ?? String(pair), "")
        }
    }

    /// Web `isValidUtm`: contains "mailbiz" or "flowbiz", case-insensitive.
    private static func isValidUtm(_ raw: String) -> Bool {
        let value = (percentDecode(raw) ?? raw).lowercased()
        return value.contains("mailbiz") || value.contains("flowbiz")
    }

    private static func percentDecode(_ value: String) -> String? {
        guard value.contains("%") else { return value }
        return value.removingPercentEncoding
    }

    /// Standard or URL-safe base64, padding optional → UTF-8 string.
    private static func decodeBase64(_ value: String) -> String? {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: hash → payload

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
            // A numeric id passes through the JS untouched; stringified here
            // to fit the typed payload.
            return JSONValue.isBoolean(number) ? (number.boolValue ? "true" : "false") : number.stringValue
        default:
            return nil
        }
    }

    /// Web `it[idx] || ''`: missing/null/empty → `""`; numbers stringified.
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

    /// Web `parseInt(it[0]) || 1`: leading decimal integer of a string (JS
    /// `parseInt` semantics — leading whitespace/sign, trailing junk
    /// ignored), numbers truncated toward zero; `NaN` *and* `0` (falsy) → 1.
    private static func webQuantity(_ value: Any?) -> Int {
        let parsed: Int?
        switch value {
        case let number as NSNumber where !JSONValue.isBoolean(number):
            let double = number.doubleValue
            parsed = double.isNaN ? nil : Int(double.rounded(.towardZero))
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

    /// 4th `its` element → properties map. Web parity: a JSON-object
    /// *string* (`tryToParseJson`); a nested object is additionally
    /// tolerated. Garbage → nil (web emits `{}` — same meaning).
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
