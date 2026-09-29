package br.com.flowbiz.onsite

import java.net.URL

/**
 * SDK configuration for [Flowbiz.initialize]. Invalid values never throw:
 * a blank [appId] makes initialization a no-op, and any other invalid value
 * is replaced or clamped as documented on it, with a debug warning.
 */
data class FlowbizConfig @JvmOverloads constructor(
    /** Tenant ID, same value as the web `app_id`. Required, non-blank. */
    val appId: String,

    /**
     * Store origin (`https://store.com`), same value as the web `baseuri`.
     * Required; prepended to path-only URLs and sent as `context.baseuri`.
     * Must be an https origin without path, query or fragment, else `""`.
     */
    val baseUri: String,

    /** Full collector base URL; must be https with a host, else [DEFAULT_COLLECTOR_URL]. */
    val collectorUrl: String = DEFAULT_COLLECTOR_URL,

    /** Verbose logging; never prints PII. */
    val debug: Boolean = false,

    /** `page.ping` cadence in seconds; clamped to ≥ 15. */
    val heartbeatIntervalSeconds: Long = DEFAULT_HEARTBEAT_SECONDS,

    /**
     * Absolute https URL the backend targets with cart-recovery links
     * (`context.recoveryUrl`, web `setRecoveryUrl`). Must be on a domain the
     * app claims via App Links. Optional; fragment stripped, null when invalid.
     */
    val recoveryUrl: String? = null,
) {
    /** [baseUri] as a nullable: null when sanitization emptied it. */
    internal val baseUriOrNull: String? get() = baseUri.ifEmpty { null }

    companion object {
        const val DEFAULT_COLLECTOR_URL = "https://collector.mailbiz.one"
        const val DEFAULT_HEARTBEAT_SECONDS = 60L
        const val MIN_HEARTBEAT_SECONDS = 15L

        /** Defensive ceiling — keeps millisecond conversion overflow-proof. */
        internal const val MAX_HEARTBEAT_SECONDS = 24L * 60L * 60L
    }
}

/** The config the SDK actually runs with, or null for a blank appId (initialize is then a no-op). */
internal object ConfigSanitizer {

    fun sanitize(config: FlowbizConfig): FlowbizConfig? {
        if (config.appId.isBlank()) {
            SdkLog.debug("FlowbizConfig.appId is blank; initialize is a no-op")
            return null
        }
        val collectorUrl = if (isValidCollectorUrl(config.collectorUrl)) {
            config.collectorUrl
        } else {
            SdkLog.debug("invalid collectorUrl (must be https:// with a host); using default")
            FlowbizConfig.DEFAULT_COLLECTOR_URL
        }
        val heartbeat = when {
            config.heartbeatIntervalSeconds < FlowbizConfig.MIN_HEARTBEAT_SECONDS -> {
                SdkLog.debug("heartbeatIntervalSeconds clamped to ${FlowbizConfig.MIN_HEARTBEAT_SECONDS}s floor")
                FlowbizConfig.MIN_HEARTBEAT_SECONDS
            }
            config.heartbeatIntervalSeconds > FlowbizConfig.MAX_HEARTBEAT_SECONDS -> {
                SdkLog.debug("heartbeatIntervalSeconds clamped to ${FlowbizConfig.MAX_HEARTBEAT_SECONDS}s ceiling")
                FlowbizConfig.MAX_HEARTBEAT_SECONDS
            }
            else -> config.heartbeatIntervalSeconds
        }
        val baseUri = sanitizeBaseUri(config.baseUri) ?: run {
            SdkLog.debug("invalid baseUri (must be an https:// origin with no path/query/fragment); path URLs will not be resolved")
            ""
        }
        val recoveryUrl = config.recoveryUrl?.let { raw ->
            sanitizeRecoveryUrl(raw) ?: run {
                SdkLog.debug("invalid recoveryUrl (must be an absolute https:// URL); omitted")
                null
            }
        }
        return config.copy(collectorUrl = collectorUrl, heartbeatIntervalSeconds = heartbeat, baseUri = baseUri, recoveryUrl = recoveryUrl)
    }

    /** The host check matters: `https://` alone parses on both platforms but is garbage. */
    fun isValidCollectorUrl(url: String): Boolean = try {
        val parsed = URL(url)
        parsed.protocol.equals("https", ignoreCase = true) && parsed.host.orEmpty().isNotEmpty()
    } catch (_: Throwable) {
        false
    }

    fun sanitizeBaseUri(value: String): String? = try {
        val trimmed = value.trim()
        val parsed = URL(trimmed)
        val ok = parsed.protocol.equals("https", ignoreCase = true) &&
            parsed.host.orEmpty().isNotEmpty() &&
            (parsed.path.isEmpty() || parsed.path == "/") &&
            parsed.query == null &&
            parsed.ref == null
        if (ok) trimmed.removeSuffix("/") else null
    } catch (_: Throwable) {
        null
    }

    fun sanitizeRecoveryUrl(value: String): String? = try {
        val trimmed = value.trim()
        val parsed = URL(trimmed)
        if (parsed.protocol.equals("https", ignoreCase = true) && parsed.host.orEmpty().isNotEmpty()) {
            trimmed.substringBefore('#')
        } else {
            null
        }
    } catch (_: Throwable) {
        null
    }
}
