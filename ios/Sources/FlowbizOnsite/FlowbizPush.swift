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
    /// `deep_link` as a `URL`, or nil when absent or rejected by
    /// `URL(string:)` — the push itself is still returned then.
    ///
    /// For routing only. On tap, call `Flowbiz.handlePushOpened(push)`
    /// rather than forwarding this URL to `Flowbiz.handleLink`: it reads the
    /// raw `deep_link`, which a `URL` cannot always represent. On iOS 13–16
    /// `URL(string:)` rejects a raw `|` (MessageBuilder writes the
    /// campaign's that way) or a non-ASCII host. On iOS 17+ it accepts them
    /// only by re-encoding the link's own escapes (`%20` → `%2520`) and
    /// punycoding the host. On iOS 13–18 it turns the fragment of a rootless
    /// custom scheme (`myapp:cart?…#promo`) into `%23promo` inside the
    /// query. A `URL` round trip can therefore lose or alter the UTMs
    /// (SPEC §10.2, §11.1).
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
            deepLink: deepLinkString.flatMap(URL.init(string:)),
            data: data,
            deepLinkString: deepLinkString
        )
    }
}
