import Foundation

/// Pure UTM extraction behind `Flowbiz.handleLink` (SPEC §11.1): a port of
/// the web tag's `Url.getQueryParameters` plus the allowlist filter and
/// per-key merge of `setUtmNavigationContext` (`onsite-core`), quirks
/// included, pinned byte-for-byte by `shared/utm-links/vectors.json`
/// (generated from the web code itself). Mirrored by the Kotlin
/// `UtmLinkParser`.
///
/// Deliberately **not** shared with `RecoveryLinkParser.queryPairs`: the
/// recovery gate reads the query differently (fragment cut first, decoded
/// keys, first occurrence wins) and its behavior is pinned by its own
/// vectors.
///
/// ## Code units, not Characters
/// Everything is split on UTF-16 code units, exactly like JS `split`.
/// Swift `Character`s are grapheme clusters: a combining mark after a
/// delimiter (`?\u{338}`, `=\u{338}`) fuses with it into one Character, so
/// Character-level searching would miss the delimiter — see the vectors
/// `combining_mark_after_separators` / `_after_question_mark`. For the same
/// reason raw keys are matched against the allowlist by code units, never
/// with `String ==` (canonical equivalence).
///
/// ## Web quirks kept on purpose
/// - The query is the text between the first `?` and the next `?`, cut at
///   the first `/#` and then the first `#`: a query inside a hash route
///   (`/#/cart?utm_source=x`) is read.
/// - Empty split parts are kept (JS `split`); a pair with no `=` yields the
///   string `"undefined"` (`decodeURIComponent(undefined)`); parts after a
///   second `=` are dropped; keys are raw (not decoded, case-sensitive).
/// - The last assignment of a key wins, **an empty value included** — an
///   empty later value (or empty `utm_flow_params` segment) erases an
///   earlier one before the non-empty filter runs.
///
/// Never throws, never traps: every failure degrades to a raw value or an
/// empty result.
enum UtmLinkParser {

    /// Ordered UTM set — allowlisted key → non-empty value, in merge order
    /// (web object insertion order).
    typealias Pairs = [(key: String, value: String)]

    /// Web `Url.UtmParameters`, in its key order — the order of `current`.
    static let allowlist = [
        "utm_source",
        "utm_medium",
        "utm_campaign",
        "utm_journey",
        "utm_journey_channel",
        "utm_journey_type",
        "utm_step_id",
        "utm_journey_version",
        "utm_journey_instance",
    ]

    /// Web `pipedUtmParametersMap`: `utm_flow_params` expands (split on `|`
    /// after decoding) into these keys, index by index, for the first
    /// `min(3, n)` parts only; the key itself is never kept.
    static let flowParamsKey = "utm_flow_params"
    static let flowParamsExpansion = ["utm_step_id", "utm_journey_version", "utm_journey_instance"]

    private static let questionMark = UInt16(UInt8(ascii: "?"))
    private static let hashMark = UInt16(UInt8(ascii: "#"))
    private static let slash = UInt16(UInt8(ascii: "/"))
    private static let ampersand = UInt16(UInt8(ascii: "&"))
    private static let equals = UInt16(UInt8(ascii: "="))
    private static let pipe = UInt16(UInt8(ascii: "|"))
    private static let percent = UInt16(UInt8(ascii: "%"))

    // MARK: Extraction

    /// The link's allowlisted UTMs with non-empty values, in allowlist
    /// order — web `currentUtms`. Empty when the link has no query or no
    /// allowlisted UTM.
    static func extract(_ url: String) -> Pairs {
        let units = Array(url.utf16)
        // Only allowlisted keys can reach `current`, so the params map keeps
        // just those (plus the flow-params expansion); last assignment wins.
        var params: [String: String] = [:]
        for pair in queryPairs(units) {
            let rawKey = units[pair.key]
            guard !rawKey.isEmpty else { continue }
            let value = pair.value.map { decodeURIComponentOrRaw(string(units[$0])) } ?? "undefined"
            if rawKey.elementsEqual(flowParamsKey.utf16) {
                let segments = split(value.utf16, on: pipe)
                for index in 0..<min(flowParamsExpansion.count, segments.count) {
                    params[flowParamsExpansion[index]] = string(segments[index])
                }
            } else if let key = allowlist.first(where: { rawKey.elementsEqual($0.utf16) }) {
                params[key] = value
            }
        }
        return allowlist.compactMap { key in
            guard let value = params[key], !value.isEmpty else { return nil }
            return (key: key, value: value)
        }
    }

    /// Web `Url.getQueryParameters`' pairs, as ranges of the link's UTF-16
    /// code units: each `&`-separated pair of the query, with the raw key
    /// (part 0) and the value (part 1; nil for a pair with no `=`, which
    /// web reads as `"undefined"`). Parts after a second `=` are dropped
    /// (web). Empty when the link has no query or an empty one (web: `{}`).
    private static func queryPairs(_ units: [UInt16]) -> [(key: Range<Int>, value: Range<Int>?)] {
        // url.split('?')[1]
        guard let firstQuestionMark = units.firstIndex(of: questionMark) else { return [] }
        var query = units[(firstQuestionMark + 1)...]
        if let nextQuestionMark = query.firstIndex(of: questionMark) {
            query = query[..<nextQuestionMark]
        }
        guard !query.isEmpty else { return [] }
        // .split('/#')[0].split('#')[0]
        if let slashHash = query.indices.first(where: { query[$0] == slash && $0 + 1 < query.endIndex && query[$0 + 1] == hashMark }) {
            query = query[..<slashHash]
        }
        if let hash = query.firstIndex(of: hashMark) {
            query = query[..<hash]
        }
        return split(query, on: ampersand).map { segment in
            let parts = split(segment, on: equals)
            return (key: parts[0].indices, value: parts.count < 2 ? nil : parts[1].indices)
        }
    }

    // MARK: Merge + render

    /// Web `{...stored, ...current}`: stored keys keep their position and
    /// take the new value; new keys are appended in `current`'s order. A
    /// merge never removes a key.
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

    /// `context.utm`: web `JSON.stringify(finalUtms)` — compact, pairs in
    /// order, `JSON.stringify` string escaping (shared with the canonical
    /// writer).
    static func render(_ pairs: Pairs) -> String {
        CanonicalJSON.renderStringPairs(pairs)
    }

    // MARK: decodeURIComponent

    /// ECMA-262 `decodeURIComponent` (Decode with an empty reserved set);
    /// on any URIError the **raw input** is returned unchanged — web
    /// `try { decodeURIComponent(v) } catch { v }`.
    ///
    /// Hand-rolled rather than `removingPercentEncoding`: Foundation is
    /// more lenient than the spec in places (e.g. a lone `%A9` decodes to
    /// U+FFFD on macOS 15 instead of failing), and its behavior may vary
    /// across OS releases; this port is pinned against a real JavaScript
    /// engine in `UtmLinkParserSuite`.
    ///
    /// - `%` must be followed by two hex digits (either case); `+` is not a
    ///   space; every escape decodes (`%26`, `%3D`, `%23`, `%25`, …).
    /// - A multi-byte UTF-8 sequence must continue with `%XX` escapes of
    ///   continuation bytes and encode a Unicode scalar in shortest form:
    ///   no overlongs, no surrogates (U+D800–DFFF), nothing above U+10FFFF.
    /// - Raw (unescaped) characters, non-ASCII included, pass through.
    static func decodeURIComponentOrRaw(_ raw: String) -> String {
        let units = Array(raw.utf16)
        guard units.contains(percent) else { return raw }
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        var k = 0
        while k < units.count {
            let unit = units[k]
            guard unit == percent else {
                out.append(unit)
                k += 1
                continue
            }
            guard let lead = escapedByte(units, at: k) else { return raw }
            k += 3
            if lead < 0x80 {
                out.append(UInt16(lead))
                continue
            }
            // Leading-ones count = sequence length; 10xxxxxx (a lone
            // continuation byte) and 5+ byte forms are URIErrors.
            let length: Int
            var scalar: UInt32
            switch lead {
            case 0xC0...0xDF: length = 2; scalar = UInt32(lead & 0x1F)
            case 0xE0...0xEF: length = 3; scalar = UInt32(lead & 0x0F)
            case 0xF0...0xF7: length = 4; scalar = UInt32(lead & 0x07)
            default: return raw
            }
            for _ in 1..<length {
                guard let continuation = escapedByte(units, at: k), continuation & 0xC0 == 0x80 else { return raw }
                scalar = scalar << 6 | UInt32(continuation & 0x3F)
                k += 3
            }
            let shortest: UInt32 = length == 2 ? 0x80 : length == 3 ? 0x800 : 0x1_0000
            guard scalar >= shortest,                      // overlong
                  !(0xD800...0xDFFF).contains(scalar),     // UTF-16 surrogate
                  scalar <= 0x10_FFFF                      // beyond Unicode
            else { return raw }
            if scalar >= 0x1_0000 {
                let offset = scalar - 0x1_0000
                out.append(UInt16(0xD800 + (offset >> 10)))
                out.append(UInt16(0xDC00 + (offset & 0x3FF)))
            } else {
                out.append(UInt16(scalar))
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// The byte of the `%XX` escape starting at `index`, or nil when there
    /// is no `%` there or it is not followed by two hex digits.
    private static func escapedByte(_ units: [UInt16], at index: Int) -> UInt8? {
        guard index + 2 < units.count, units[index] == percent,
              let high = hexValue(units[index + 1]), let low = hexValue(units[index + 2])
        else { return nil }
        return high << 4 | low
    }

    private static func hexValue(_ unit: UInt16) -> UInt8? {
        switch unit {
        case 0x30...0x39: return UInt8(unit - 0x30)       // 0-9
        case 0x41...0x46: return UInt8(unit - 0x41 + 10)  // A-F
        case 0x61...0x66: return UInt8(unit - 0x61 + 10)  // a-f
        default: return nil
        }
    }

    // MARK: JS split

    /// JS `String.prototype.split(separator)` over code units: every part
    /// is kept, empty ones included (leading, inner and trailing).
    private static func split<C: Collection>(_ units: C, on separator: UInt16) -> [C.SubSequence] where C.Element == UInt16 {
        units.split(separator: separator, omittingEmptySubsequences: false)
    }

    /// Code units → String. Parts are always cut at ASCII delimiters of a
    /// well-formed string, so they are well-formed themselves.
    private static func string<C: Collection>(_ units: C) -> String where C.Element == UInt16 {
        String(decoding: units, as: UTF16.self)
    }
}
