import Foundation

/// Port of the web tag's `Url.getQueryParameters` + `setUtmNavigationContext`,
/// quirks included; pinned by `shared/utm-links/vectors.json`.
///
/// Links are split on UTF-16 code units, as JS `split` does, never on
/// `Character`s: a combining mark after a delimiter would fuse with it.
enum UtmLinkParser {

    typealias Pairs = [(key: String, value: String)]

    static let allowlist = [
        "utm_source", "utm_medium", "utm_campaign", "utm_journey", "utm_journey_channel",
        "utm_journey_type", "utm_step_id", "utm_journey_version", "utm_journey_instance",
    ]
    private static let flowParams = ["utm_step_id", "utm_journey_version", "utm_journey_instance"]

    static func extract(_ url: String) -> Pairs {
        var params: [String: String] = [:]
        for pair in split(query(Array(url.utf16)), "&") {
            let parts = split(pair, "=")
            let value = parts.count > 1 ? decodeURIComponentOrRaw(string(parts[1])) : "undefined"
            if parts[0].elementsEqual("utm_flow_params".utf16) {
                for (key, part) in zip(flowParams, split(value.utf16, "|")) { params[key] = string(part) }
            } else if let key = allowlist.first(where: { $0.utf16.elementsEqual(parts[0]) }) {
                params[key] = value
            }
        }
        return allowlist.compactMap { key in params[key].flatMap { $0.isEmpty ? nil : (key: key, value: $0) } }
    }

    /// `href.split('?')[1].split('/#')[0].split('#')[0]`
    private static func query(_ url: [UInt16]) -> ArraySlice<UInt16> {
        guard let mark = url.firstIndex(of: unit("?")) else { return [] }
        var query = url[(mark + 1)...].prefix { $0 != unit("?") }
        if let hash = query.firstIndex(of: unit("#")) {
            query = query[..<hash]
            if query.last == unit("/") { query = query.dropLast() }
        }
        return query
    }

    /// `{...stored, ...current}`
    static func merge(stored: Pairs, current: Pairs) -> Pairs {
        var merged = stored
        for pair in current {
            if let index = merged.firstIndex(where: { $0.key == pair.key }) {
                merged[index].value = pair.value
            } else {
                merged.append(pair)
            }
        }
        return merged
    }

    /// `decodeURIComponent(raw)`, or `raw` where it throws. Hand-rolled:
    /// `removingPercentEncoding` is lenient (a lone `%A9` becomes U+FFFD) and
    /// drops a leading BOM, as `String(bytes:encoding:)` does on iOS 26.
    static func decodeURIComponentOrRaw(_ raw: String) -> String {
        var bytes: [UInt8] = []
        var rest = raw.utf8[...]
        while let byte = rest.popFirst() {
            guard byte == UInt8(ascii: "%") else { bytes.append(byte); continue }
            guard let high = hexValue(rest.popFirst()), let low = hexValue(rest.popFirst()) else { return raw }
            bytes.append(high << 4 | low)
        }
        let invalid = transcode(bytes.makeIterator(), from: UTF8.self, to: UTF16.self, stoppingOnError: true) { _ in }
        return invalid ? raw : String(decoding: bytes, as: UTF8.self)
    }

    /// ASCII only: `UInt8(_:radix:)` would also accept a sign.
    private static func hexValue(_ byte: UInt8?) -> UInt8? {
        guard let byte else { return nil }
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    private static func split<C: Collection>(_ units: C, _ separator: Unicode.Scalar) -> [C.SubSequence] where C.Element == UInt16 {
        units.split(separator: unit(separator), omittingEmptySubsequences: false)
    }

    private static func string<C: Collection>(_ units: C) -> String where C.Element == UInt16 {
        String(decoding: units, as: UTF16.self)
    }

    private static func unit(_ ascii: Unicode.Scalar) -> UInt16 {
        UInt16(ascii.value)
    }
}
