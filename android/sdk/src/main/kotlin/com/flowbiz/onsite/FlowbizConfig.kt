package com.flowbiz.onsite

import java.net.URL

/**
 * Public SDK configuration (SPEC §2). Immutable value type.
 *
 * Invalid values never throw (SPEC §3) — they are sanitized at
 * [Flowbiz.initialize]:
 * - blank/whitespace [appId] → initialization is a **no-op** (debug warning);
 * - non-HTTPS / unparseable / hostless [collectorUrl] → replaced with
 *   [DEFAULT_COLLECTOR_URL] (debug warning);
 * - [heartbeatIntervalSeconds] clamped to the 15 s floor (SPEC §2) and a
 *   defensive 24 h ceiling;
 * - invalid [baseUri] (must be an https:// origin, no path/query/fragment)
 *   → replaced with `""` (debug warning);
 * - invalid [recoveryUrl] (must be an absolute https:// URL) → replaced with
 *   `null` (debug warning).
 *
 * Session timeout, dedup window, queue cap and connection timeout are
 * internal constants, not config knobs (SPEC §2).
 */
data class FlowbizConfig @JvmOverloads constructor(
    /** Tenant ID, same value as the web `app_id`. Required, non-blank. */
    val appId: String,

    /**
     * Store origin (`https://store.com`), same value as the web `baseuri`.
     * Required; prepended to path-only URLs (spec §5) and sent as
     * `context.baseuri`. Sanitized to `""` when invalid (spec §3).
     */
    val baseUri: String,

    /** Full collector base URL; must be HTTPS. */
    val collectorUrl: String = DEFAULT_COLLECTOR_URL,

    /** Verbose logging; never prints PII (SPEC §12). */
    val debug: Boolean = false,

    /** `page.ping` cadence in seconds (SPEC §8); clamped to ≥ 15. */
    val heartbeatIntervalSeconds: Long = DEFAULT_HEARTBEAT_SECONDS,

    /**
     * Absolute https URL the backend targets with cart-recovery links
     * (`context.recoveryUrl`, web `setRecoveryUrl`). Must be on a domain the
     * app claims via App Links. Optional; null when invalid.
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

/**
 * Config validation (SPEC §2/§3): produces the sanitized config the SDK
 * actually runs with, or null when [FlowbizConfig.appId] is blank (in which
 * case initialization must be a complete no-op). Never throws.
 */
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

    /**
     * Valid iff the URL parses, the scheme is `https` (case-insensitive) and
     * the host is non-empty. The non-empty host requirement is deliberate —
     * `https://` alone parses on both platforms but is garbage; validation
     * strictness is aligned with the iOS `ConfigSanitizer`.
     */
    fun isValidCollectorUrl(url: String): Boolean = try {
        val parsed = URL(url)
        parsed.protocol.equals("https", ignoreCase = true) && parsed.host.orEmpty().isNotEmpty()
    } catch (_: Throwable) {
        false
    }

    /**
     * Spec §3: absolute https origin, no path (or exactly "/"), no query, no
     * fragment. Returns the trimmed origin without a trailing slash.
     */
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

    /** Spec §3: absolute https URL; fragment stripped. */
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
