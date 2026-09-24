import Foundation

/// Result of `Flowbiz.handlePush` (SPEC §10.2/§10.3): a decoded Flowbiz
/// push payload. `type` is free-form — new push kinds require no SDK
/// update; the SDK parses best-effort regardless of `version` (forward
/// compatibility).
public struct FlowbizPush: Sendable {

    /// Contract version (`v`); absent/malformed defaults to 1.
    public let version: Int
    /// Free-form push kind, e.g. `"cart_recovery"`. Always non-empty.
    public let type: String
    public let title: String?
    public let body: String?
    /// `deep_link` as a `URL`, or nil when absent or unparseable — the push
    /// itself is still returned then. On iOS 13–16, whose `URL(string:)`
    /// rejects any character outside RFC 3986, a link carrying one — the
    /// campaign's raw `|` MessageBuilder writes — is percent-encoded where
    /// needed and parsed again, so it still routes (see
    /// `PushPayloadParser.deepLinkURL`).
    ///
    /// For routing only. On tap, call `Flowbiz.handlePushOpened(push)`
    /// rather than forwarding this URL to `Flowbiz.handleLink`: it reads the
    /// raw `deep_link`, which a `URL` cannot always represent. iOS 13–16
    /// still reject a link without a scheme, a non-ASCII host, a bare `%`
    /// or a second `#`. On iOS 17+ `URL(string:)` accepts those only by
    /// re-encoding the link's own escapes (`%20` → `%2520`) and punycoding
    /// the host. On iOS 13–18 it turns the fragment of a rootless custom
    /// scheme (`myapp:cart?…#promo`) into `%23promo` inside the query. A
    /// `URL` round trip can therefore lose or alter the UTMs (SPEC §10.2,
    /// §11.1).
    public let deepLink: URL?
    /// `data` object of the decoded payload; empty when absent.
    public let data: [String: JSONValue]

    /// The raw `deep_link` string — kept internally so `recoveryPayload`
    /// and `Flowbiz.handlePushOpened` work even when `URL(string:)` and the
    /// raw string disagree.
    let deepLinkString: String?

    /// Convenience for cart-recovery pushes (SPEC §10.2: the `_mb_cr_`
    /// link rides in `deep_link`): the raw deep link run through the
    /// `Flowbiz.handleLink` decoder. Nil when there is no deep link or it
    /// carries no decodable `_mb_cr_` value. Pure: no tenant check and **no
    /// UTM capture** (receiving a push is not a click). When the user taps
    /// the notification, call `Flowbiz.handlePushOpened(push)` instead: it
    /// captures the deep link's UTMs and returns this payload, or nil for
    /// another tenant's link once initialized (SPEC §10.2, §10.3, §11.1).
    public var recoveryPayload: RecoveryPayload? {
        RecoveryLinkParser.parse(deepLinkString)
    }
}

/// Pure parser behind `Flowbiz.handlePush` (SPEC §10.2): the value of the
/// `"flowbiz"` marker key — a JSON-encoded *string* (the cross-platform
/// contract; FCM data messages are flat maps) — decoded into a
/// `FlowbizPush`. APNs payloads are nested JSON, so an iOS sender *could*
/// put an object there; that is tolerated leniently (`parse(object:)`),
/// documented in `shared/push-samples/samples.json`.
///
/// Tolerant by design: unknown `v` values and unknown fields parse
/// best-effort (forward compatibility). Nil only for undecodable JSON, a
/// non-object root, or a missing/empty `type`. Never throws.
enum PushPayloadParser {

    static let markerKey = "flowbiz"

    static func parse(_ markerValue: String) -> FlowbizPush? {
        guard
            let root = try? JSONSerialization.jsonObject(with: Data(markerValue.utf8)),
            let payload = root as? [String: Any]
        else { return nil }
        return parse(object: payload)
    }

    static func parse(object payload: [String: Any]) -> FlowbizPush? {
        guard let type = payload["type"] as? String, !type.isEmpty else { return nil }
        let version: Int
        if let number = payload["v"] as? NSNumber, !JSONValue.isBoolean(number) {
            version = number.intValue
        } else {
            version = 1
        }
        let data = (payload["data"] as? [String: Any])
            .flatMap(JSONValue.objectFromFoundation) ?? [:]
        let deepLinkString = payload["deep_link"] as? String
        return FlowbizPush(
            version: version,
            type: type,
            title: payload["title"] as? String,
            body: payload["body"] as? String,
            deepLink: deepLinkString.flatMap { deepLinkURL($0) },
            data: data,
            deepLinkString: deepLinkString
        )
    }

    /// `deep_link` → `URL` for routing (SPEC §10.2). `parse` (default
    /// `URL(string:)`) decides first: on iOS 17+ it percent-encodes invalid
    /// characters itself (punycoding a non-ASCII host), so its result is
    /// final there and unchanged by this function. iOS 13–16's parser
    /// instead rejects any character outside RFC 3986, and MessageBuilder
    /// writes the campaign's `|` raw (`utm_campaign=jornadas|cart|…`), so
    /// such links came out nil. Only for a rejected link,
    /// `encodingInvalidCharacters` repairs it and it is parsed again: the
    /// repaired link keeps the raw link's query — UTMs and `_mb_cr_`
    /// included — and routes. Still nil when the repair cannot help (no
    /// scheme, a non-ASCII host, a bare `%`, a second `#`), as before.
    ///
    /// `parse` is a seam: tests pass the legacy CFURL parser to stand in
    /// for iOS 13–16. Never throws.
    static func deepLinkURL(_ string: String, parse: (String) -> URL? = { URL(string: $0) }) -> URL? {
        if let url = parse(string) { return url }
        guard let repaired = encodingInvalidCharacters(string), repaired != string else { return nil }
        return parse(repaired)
    }

    /// `link` with every character outside RFC 3986 (unreserved, reserved
    /// and `%`) percent-encoded as UTF-8, after the `scheme:` or
    /// `scheme://authority` prefix only. Existing escapes and every
    /// delimiter are kept byte for byte. Nil when the link does not start
    /// with a scheme — only absolute links are repaired, not a `//host`
    /// reference, a leading space or BOM — or when the authority itself
    /// holds such a character: a non-ASCII host needs IDNA, and
    /// percent-encoding it would name another host.
    static func encodingInvalidCharacters(_ link: String) -> String? {
        let scalars = link.unicodeScalars
        guard let pathStart = prefixEnd(of: scalars) else { return nil }
        let prefix = String(scalars[..<pathStart])
        guard prefix.unicodeScalars.allSatisfy(rfc3986.contains),
              let rest = String(scalars[pathStart...]).addingPercentEncoding(withAllowedCharacters: rfc3986)
        else { return nil }
        return prefix + rest
    }

    /// RFC 3986 unreserved and reserved characters, plus `%` so existing
    /// escapes survive.
    private static let rfc3986 = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
    )

    /// End of the `scheme:` prefix — extended over `//authority` up to the
    /// first `/`, `?` or `#` when one follows — or nil when the link does
    /// not start with an RFC 3986 scheme (`ALPHA *(ALPHA / DIGIT / "+" /
    /// "-" / ".") ":"`). Scanned by Unicode scalar: a combining mark must
    /// not glue onto a delimiter the way it does in a `Character`.
    private static func prefixEnd(of scalars: String.UnicodeScalarView) -> String.Index? {
        func isAlpha(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        }
        func isSchemeCharacter(_ scalar: Unicode.Scalar) -> Bool {
            isAlpha(scalar) || ("0"..."9").contains(scalar) || scalar == "+" || scalar == "-" || scalar == "."
        }
        guard let colon = scalars.firstIndex(of: ":"),
              let first = scalars.first, isAlpha(first),
              scalars[..<colon].allSatisfy(isSchemeCharacter)
        else { return nil }
        let afterColon = scalars.index(after: colon)
        guard scalars[afterColon...].starts(with: "//".unicodeScalars) else { return afterColon }
        let authorityStart = scalars.index(afterColon, offsetBy: 2)
        return scalars[authorityStart...].firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? scalars.endIndex
    }
}
