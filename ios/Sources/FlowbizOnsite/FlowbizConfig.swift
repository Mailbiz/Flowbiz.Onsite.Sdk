import Foundation

/// Invalid values never throw: a blank `appId` makes initialize a no-op, others are replaced or clamped.
public struct FlowbizConfig: Sendable, Equatable {

    public static let defaultCollectorUrl = "https://collector.mailbiz.one"

    static let defaultHeartbeatInterval: TimeInterval = 60
    static let minHeartbeatInterval: TimeInterval = 15
    // Keeps the Int64 millisecond conversion from overflowing.
    static let maxHeartbeatInterval: TimeInterval = 24 * 60 * 60

    /// Same value as the web tag's `app_id`.
    public let appId: String

    /// The store's https origin, as the web tag's `baseuri`; path-only URLs are resolved against it.
    public let baseUri: String

    /// Collector base URL; must be https with a host, else the default is used.
    public let collectorUrl: String
    public let debug: Bool

    /// `page.ping` cadence, clamped to 15 s…24 h.
    public let heartbeatInterval: TimeInterval

    /// Where cart-recovery links point (web `setRecoveryUrl`); an https URL the app claims via Universal Links.
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

    var baseUriOrNil: String? { baseUri.isEmpty ? nil : baseUri }
}

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

    // The host check matters: `https://` alone parses.
    static func isValidCollectorUrl(_ url: String) -> Bool {
        guard let parsed = URL(string: url),
              parsed.scheme?.lowercased() == "https",
              let host = parsed.host, !host.isEmpty
        else { return false }
        return true
    }

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
