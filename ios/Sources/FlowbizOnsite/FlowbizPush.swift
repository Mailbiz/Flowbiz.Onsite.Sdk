import Foundation

public struct FlowbizPush: Sendable {

    /// Contract version (`v`); 1 when absent or malformed.
    public let version: Int
    /// Free-form push kind; never empty.
    public let type: String
    public let title: String?
    public let body: String?
    /// For routing only: on tap call `Flowbiz.handlePushOpened`, as a `URL` round trip can alter the UTMs.
    public let deepLink: URL?
    public let data: [String: JSONValue]

    let deepLinkString: String?

    /// Pure decode (no UTM capture, no tenant check); on tap, call `Flowbiz.handlePushOpened` instead.
    public var recoveryPayload: RecoveryPayload? {
        RecoveryLinkParser.parse(deepLinkString)
    }
}

// The marker is a JSON string, as FCM data is a flat map; APNs may nest an object, hence parse(object:).
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

    // iOS 13–16's URL(string:) rejects non-RFC 3986 characters, like the raw `|` in utm_campaign.
    static func deepLinkURL(_ string: String, parse: (String) -> URL? = { URL(string: $0) }) -> URL? {
        parse(string) ?? encodingInvalidCharacters(string).flatMap(parse)
    }

    // Nil unless scheme and authority need no encoding: encoding a non-ASCII host would name another host.
    static func encodingInvalidCharacters(_ link: String) -> String? {
        guard let encoded = link.addingPercentEncoding(withAllowedCharacters: rfc3986),
              let prefix = encoded.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:(//[^/?#]*)?", options: .regularExpression),
              link.utf8.starts(with: encoded[prefix].utf8)
        else { return nil }
        return encoded
    }

    // Plus `%`, so existing escapes are kept.
    private static let rfc3986 = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
    )
}
