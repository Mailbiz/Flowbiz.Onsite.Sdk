package com.flowbiz.onsite

import android.net.Uri
import org.json.JSONObject

/**
 * Result of [Flowbiz.handlePush] (SPEC §10.2/§10.3): a decoded Flowbiz push
 * payload. [type] is free-form — new push kinds require no SDK update; the
 * SDK parses best-effort regardless of [version] (forward compatibility).
 *
 * Immutable. Not a data class on purpose: the raw deep-link string is an
 * internal field (the platform [Uri] is derived lazily so the type stays
 * constructible where `android.net.Uri` does not exist, e.g. JVM tests).
 */
class FlowbizPush internal constructor(
    /** Contract version (`v`); absent/malformed defaults to 1. */
    val version: Int,
    /** Free-form push kind, e.g. `"cart_recovery"`. Always non-empty. */
    val type: String,
    val title: String?,
    val body: String?,
    /** `data` object of the decoded payload; empty when absent. */
    val data: Map<String, Any?>,
    internal val deepLinkString: String?,
) {

    /**
     * `deep_link` as a [Uri], or null when absent. `Uri.parse` is lenient
     * (it validates nothing), so this is null only for an absent value; any
     * parse surprise degrades to null with the push still returned.
     */
    val deepLink: Uri?
        get() = try {
            deepLinkString?.let(Uri::parse)
        } catch (t: Throwable) {
            null
        }

    /**
     * Convenience for cart-recovery pushes (SPEC §10.2: the `_mb_cr_`
     * link rides in `deep_link`): the deep link run through the
     * [Flowbiz.handleLink] decoder. Null when there is no deep link or it
     * carries no decodable `_mb_cr_` value. Pure, like `handleLink`.
     */
    val recoveryPayload: RecoveryPayload?
        get() = RecoveryLinkParser.parse(deepLinkString)
}

/**
 * Pure parser behind [Flowbiz.handlePush] (SPEC §10.2): the value of the
 * `"flowbiz"` marker key — a JSON-encoded *string* (FCM data messages are
 * flat `Map<String, String>`) — decoded into a [FlowbizPush].
 *
 * Tolerant by design: unknown `v` values and unknown fields parse
 * best-effort (forward compatibility). Null only for undecodable JSON, a
 * non-object root, or a missing/empty `type`. Never throws.
 */
internal object PushPayloadParser {

    const val MARKER_KEY = "flowbiz"

    fun parse(markerValue: String?): FlowbizPush? {
        if (markerValue == null) return null
        return try {
            fromObject(JSONObject(markerValue))
        } catch (t: Throwable) {
            null
        }
    }

    private fun fromObject(payload: JSONObject): FlowbizPush? {
        val type = (payload.opt("type") as? String)?.takeIf { it.isNotEmpty() } ?: return null
        val version = (payload.opt("v") as? Number)?.toInt() ?: 1
        val data = payload.optJSONObject("data")?.let(JsonPlain::toPlainMap) ?: emptyMap()
        return FlowbizPush(
            version = version,
            type = type,
            title = payload.opt("title") as? String,
            body = payload.opt("body") as? String,
            data = data,
            deepLinkString = payload.opt("deep_link") as? String,
        )
    }
}
