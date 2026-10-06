package br.com.flowbiz.onsite

import java.net.URL

/** Invalid values never throw: a blank [appId] makes initialize a no-op, others are replaced or clamped. */
data class FlowbizConfig @JvmOverloads constructor(
    /** Same value as the web tag's `app_id`. */
    val appId: String,

    /** The store's https origin, as the web tag's `baseuri`; path-only URLs are resolved against it. */
    val baseUri: String,

    /** Collector base URL; must be https with a host, else the default is used. */
    val collectorUrl: String = DEFAULT_COLLECTOR_URL,
    val debug: Boolean = false,

    /** `page.ping` cadence, clamped to 15 s…24 h. */
    val heartbeatIntervalSeconds: Long = DEFAULT_HEARTBEAT_SECONDS,

    /** Where cart-recovery links point (web `setRecoveryUrl`); an https URL the app claims via App Links. */
    val recoveryUrl: String? = null,
) {
    internal val baseUriOrNull: String? get() = baseUri.ifEmpty { null }

    companion object {
        const val DEFAULT_COLLECTOR_URL = "https://collector.mailbiz.one"
        const val DEFAULT_HEARTBEAT_SECONDS = 60L
        const val MIN_HEARTBEAT_SECONDS = 15L

        // Keeps the millisecond conversion overflow-proof.
        internal const val MAX_HEARTBEAT_SECONDS = 24L * 60L * 60L
    }
}

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
