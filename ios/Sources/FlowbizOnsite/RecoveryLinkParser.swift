import Foundation

/// Pure decoder behind `Flowbiz.handleLink` (SPEC §11): URL string →
/// `mb_recovery` query value → LZ-string decompress → hash JSON
/// `{t, u, c, its: [[qty, product_id, sku, recovery_properties?]]}` →
/// `RecoveryPayload`.
///
/// Operates on the raw URL *string* (the facade adapts `URL` via
/// `absoluteString`) with manual query splitting — `URLComponents` decodes
/// percent-escapes in `queryItems` but not `+`, and the two SDKs must
/// tolerate identical encodings, so both share this string-level parsing.
///
/// ## Percent-encoding tolerance
/// The compressed value's alphabet (`A-Za-z0-9+-$`) is URL-safe by design,
/// so the web puts the hash in links *unencoded* — but intermediate link
/// handling may percent-encode (`+` → `%2B`, `$` → `%24`) or turn `+` into
/// a space. The parser tries the raw value first (the decompressor itself
/// restores `" "` → `"+"`, reference behavior), then a percent-decoded
/// variant (decoding `%XX` only — never `+` → space). First candidate that
/// decodes to a valid payload wins.
///
/// ## Hash → payload mapping (web `buildCartRecoveryPayload` parity)
/// - `t`, `u`, `c` must be present and non-empty, `its` a non-empty array —
///   else the whole payload is nil (web `getRecoveryDataFromQuery`
///   validation). `t` (tenant) is *not* compared against the SDK config:
///   `handleLink` is pure and callable before `initialize` (SPEC §3).
/// - per item: `product_id`/`sku` from index 1/2 (missing → `""`), quantity
///   `parseInt(it[0]) || 1`, `recovery_properties` from index 3
///   (JSON-object string; garbage → nil). Non-array `its` elements are
///   skipped (the JS would string-index them into garbage — not emulated).
///
/// Pure, synchronous, never throws.
enum RecoveryLinkParser {

    private static let param = "mb_recovery"

    static func parse(_ url: String?) -> RecoveryPayload? {
        guard let url, let raw = queryParameter(url) else { return nil }
        var candidates = [raw]
        if let decoded = percentDecode(raw), decoded != raw {
            candidates.append(decoded)
        }
        for candidate in candidates {
            guard let json = LZString.decompressFromEncodedURIComponent(candidate) else { continue }
            if let payload = mapHash(json) {
                return payload
            }
        }
        return nil
    }

    /// Raw (undecoded) value of the first `mb_recovery` pair in the query string.
    private static func queryParameter(_ url: String) -> String? {
        guard let queryStart = url.firstIndex(of: "?") else { return nil }
        var query = url[url.index(after: queryStart)...]
        if let fragmentStart = query.firstIndex(of: "#") {
            query = query[..<fragmentStart]
        }
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let key: Substring
            let value: Substring
            if let eq = pair.firstIndex(of: "=") {
                key = pair[..<eq]
                value = pair[pair.index(after: eq)...]
            } else {
                key = pair
                value = ""
            }
            if key == param || percentDecode(String(key)) == param, !value.isEmpty {
                return String(value)
            }
        }
        return nil
    }

    /// `%XX` decoding that does NOT decode `+` to a space (the LZ alphabet
    /// contains `+`); `removingPercentEncoding` has exactly that behavior.
    /// Returns nil for malformed escapes — the raw candidate then stands on
    /// its own.
    private static func percentDecode(_ value: String) -> String? {
        guard value.contains("%") else { return value }
        return value.removingPercentEncoding
    }

    // MARK: hash → payload

    private static func mapHash(_ json: String) -> RecoveryPayload? {
        guard
            let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
            let hash = root as? [String: Any],
            let cartId = nonEmptyString(hash["c"]),
            let userId = nonEmptyString(hash["u"]),
            nonEmptyString(hash["t"]) != nil,
            let its = hash["its"] as? [Any],
            !its.isEmpty
        else { return nil }

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
