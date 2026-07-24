import Foundation

/// Public SDK configuration (SPEC §2). Immutable value type, `Sendable`.
///
/// Invalid values never throw (SPEC §3) — they are sanitized at
/// `Flowbiz.initialize`:
/// - blank/whitespace `appId` → initialization is a **no-op** (debug warning);
/// - non-HTTPS / unparseable / hostless `collectorUrl` → replaced with
///   `defaultCollectorUrl` (debug warning);
/// - `heartbeatInterval` clamped to the 15 s floor (SPEC §2) and a defensive
///   24 h ceiling (non-finite values clamp to the floor).
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

    /// Full collector base URL; must be HTTPS.
    public let collectorUrl: String

    /// Verbose logging; never prints PII (SPEC §12).
    public let debug: Bool

    /// `page.ping` cadence in seconds (SPEC §8); clamped to ≥ 15.
    public let heartbeatInterval: TimeInterval

    public init(
        appId: String,
        collectorUrl: String = FlowbizConfig.defaultCollectorUrl,
        debug: Bool = false,
        heartbeatInterval: TimeInterval = 60
    ) {
        self.appId = appId
        self.collectorUrl = collectorUrl
        self.debug = debug
        self.heartbeatInterval = heartbeatInterval
    }
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
        return FlowbizConfig(
            appId: config.appId,
            collectorUrl: collectorUrl,
            debug: config.debug,
            heartbeatInterval: heartbeat
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
}
