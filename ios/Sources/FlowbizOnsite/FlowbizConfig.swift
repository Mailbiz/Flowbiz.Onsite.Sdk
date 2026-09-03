import Foundation

/// Public SDK configuration (SPEC §2). Immutable value type, `Sendable`.
///
/// Invalid values never throw (SPEC §3) — they are sanitized at
/// `Flowbiz.initialize`:
/// - blank/whitespace `appId` → initialization is a **no-op** (debug warning);
/// - non-HTTPS / unparseable / hostless `collectorUrl` → replaced with
///   `defaultCollectorUrl` (debug warning);
/// - `heartbeatInterval` clamped to the 15 s floor (SPEC §2) and a defensive
///   24 h ceiling (non-finite values clamp to the floor);
/// - invalid `baseUri` (must be an https:// origin, no path/query/fragment)
///   → replaced with `""` (debug warning);
/// - invalid `recoveryUrl` (must be an absolute https:// URL) → replaced
///   with `nil` (debug warning).
///
/// Session timeout, dedup window, queue cap and connection timeout are
/// internal constants, not config knobs (SPEC §2).
public struct FlowbizConfig: Sendable, Equatable {

    public static let defaultCollectorUrl = "https://collector.mailbiz.one"

    static let defaultHeartbeatInterval: TimeInterval = 60
    static let minHeartbeatInterval: TimeInterval = 15
    /// Defensive ceiling — keeps millisecond conversion overflow-proof.
    static let maxHeartbeatInterval: TimeInterval = 24 * 60 * 60

    /// Tenant ID, same value as the web `app_id`. Required, non-blank.
    public let appId: String

    /// Store origin (`https://store.com`), same value as the web `baseuri`.
    /// Required; prepended to path-only URLs (spec §5) and sent as
    /// `context.baseuri`. Sanitized to `""` when invalid (spec §3).
    public let baseUri: String

    /// Full collector base URL; must be HTTPS.
    public let collectorUrl: String

    /// Verbose logging; never prints PII (SPEC §12).
    public let debug: Bool

    /// `page.ping` cadence in seconds (SPEC §8); clamped to ≥ 15.
    public let heartbeatInterval: TimeInterval

    /// Absolute https URL the backend targets with cart-recovery links
    /// (`context.recoveryUrl`, web `setRecoveryUrl`). Must be on a domain
    /// the app claims via Universal Links. Optional; nil when invalid.
    public let recoveryUrl: String?

    public init(
        appId: String,
        baseUri: String,
        collectorUrl: String = FlowbizConfig.defaultCollectorUrl,
        debug: Bool = false,
        heartbeatInterval: TimeInterval = 60,
        recoveryUrl: String? = nil
    ) {
        self.appId = appId
        self.baseUri = baseUri
        self.collectorUrl = collectorUrl
        self.debug = debug
        self.heartbeatInterval = heartbeatInterval
        self.recoveryUrl = recoveryUrl
    }

    /// `baseUri` as an optional: nil when sanitization emptied it.
    var baseUriOrNil: String? { baseUri.isEmpty ? nil : baseUri }
}

/// Config validation (SPEC §2/§3): produces the sanitized config the SDK
/// actually runs with, or nil when `appId` is blank (in which case
/// initialization must be a complete no-op). Never throws.
enum ConfigSanitizer {

    static func sanitize(_ config: FlowbizConfig) -> FlowbizConfig? {
        guard !config.appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            SdkLog.debug("FlowbizConfig.appId is blank; initialize is a no-op")
            return nil
        }
        let collectorUrl: String
        if isValidCollectorUrl(config.collectorUrl) {
            collectorUrl = config.collectorUrl
        } else {
            SdkLog.debug("invalid collectorUrl (must be https:// with a host); using default")
            collectorUrl = FlowbizConfig.defaultCollectorUrl
        }
        var heartbeat = config.heartbeatInterval
        if !heartbeat.isFinite || heartbeat < FlowbizConfig.minHeartbeatInterval {
            SdkLog.debug("heartbeatInterval clamped to \(Int(FlowbizConfig.minHeartbeatInterval))s floor")
            heartbeat = FlowbizConfig.minHeartbeatInterval
        } else if heartbeat > FlowbizConfig.maxHeartbeatInterval {
            SdkLog.debug("heartbeatInterval clamped to \(Int(FlowbizConfig.maxHeartbeatInterval))s ceiling")
            heartbeat = FlowbizConfig.maxHeartbeatInterval
        }
        let baseUri: String
        if let valid = sanitizeBaseUri(config.baseUri) {
            baseUri = valid
        } else {
            SdkLog.debug("invalid baseUri (must be an https:// origin with no path/query/fragment); path URLs will not be resolved")
            baseUri = ""
        }
        var recoveryUrl: String? = nil
        if let raw = config.recoveryUrl {
            recoveryUrl = sanitizeRecoveryUrl(raw)
            if recoveryUrl == nil {
                SdkLog.debug("invalid recoveryUrl (must be an absolute https:// URL); omitted")
            }
        }
        return FlowbizConfig(
            appId: config.appId,
            baseUri: baseUri,
            collectorUrl: collectorUrl,
            debug: config.debug,
            heartbeatInterval: heartbeat,
            recoveryUrl: recoveryUrl
        )
    }

    /// Valid iff the URL parses, the scheme is `https` (case-insensitive)
    /// and the host is non-empty. The non-empty host requirement is
    /// deliberate — `https://` alone parses on both platforms but is
    /// garbage; validation strictness is aligned with the Android
    /// `ConfigSanitizer`.
    static func isValidCollectorUrl(_ url: String) -> Bool {
        guard let parsed = URL(string: url),
              parsed.scheme?.lowercased() == "https",
              let host = parsed.host, !host.isEmpty
        else { return false }
        return true
    }

    /// Spec §3: absolute https origin, no path (or exactly "/"), no query,
    /// no fragment. Returns the trimmed origin without a trailing slash.
    static func sanitizeBaseUri(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil
        else { return nil }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    /// Spec §3: absolute https URL; fragment stripped.
    static func sanitizeRecoveryUrl(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        if let hash = trimmed.firstIndex(of: "#") {
            return String(trimmed[..<hash])
        }
        return trimmed
    }
}
