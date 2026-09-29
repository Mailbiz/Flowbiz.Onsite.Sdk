import Foundation

/// A decoded Flowbiz push, from `Flowbiz.handlePush`. `type` is free-form and
/// any `version` parses, so new push kinds need no SDK update.
public struct FlowbizPush: Sendable {

    /// Contract version (`v`); absent/malformed defaults to 1.
    public let version: Int
    /// Free-form push kind, e.g. `"cart_recovery"`. Always non-empty.
    public let type: String
    public let title: String?
    public let body: String?
    /// `deep_link` as a `URL`, for routing; nil when absent or unparseable
    /// (the push itself is still returned). On tap, call
    /// `Flowbiz.handlePushOpened(push)`, not `handleLink(push.deepLink)`: a
    /// `URL` round trip can alter the link's UTMs.
    public let deepLink: URL?
    /// `data` object of the decoded payload; empty when absent.
    public let data: [String: JSONValue]

    /// The raw `deep_link`, unaltered by a `URL` round trip.
    let deepLinkString: String?

    /// The cart of a cart-recovery push: `deep_link` decoded like
    /// `Flowbiz.handleLink`, nil when it carries no decodable `_mb_cr_`.
    /// Pure: no tenant check, no UTM capture.
    public var recoveryPayload: RecoveryPayload? {
        RecoveryLinkParser.parse(deepLinkString)
    }
}

/// The `"flowbiz"` marker value is a JSON string, as FCM data messages are
/// flat maps; APNs allows a nested object, tolerated by `parse(object:)`.
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

    /// iOS 13–16's `URL(string:)` rejects any character outside RFC 3986,
    /// such as the raw `|` MessageBuilder writes in `utm_campaign`: a
    /// rejected link is parsed again with those characters encoded. `parse`
    /// lets tests stand in the iOS 13–16 parser.
    static func deepLinkURL(_ string: String, parse: (String) -> URL? = { URL(string: $0) }) -> URL? {
        parse(string) ?? encodingInvalidCharacters(string).flatMap(parse)
    }

    /// `link` with its non-RFC 3986 characters percent-encoded, or nil unless
    /// its `scheme:` or `scheme://authority` needs none: encoding a
    /// non-ASCII host would name another host.
    static func encodingInvalidCharacters(_ link: String) -> String? {
        guard let encoded = link.addingPercentEncoding(withAllowedCharacters: rfc3986),
              let prefix = encoded.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:(//[^/?#]*)?", options: .regularExpression),
              link.utf8.starts(with: encoded[prefix].utf8)
        else { return nil }
        return encoded
    }

    /// RFC 3986 unreserved and reserved characters, plus `%` so existing
    /// escapes are kept.
    private static let rfc3986 = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
    )
}
