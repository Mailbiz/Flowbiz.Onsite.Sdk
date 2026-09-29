package br.com.flowbiz.onsite

import android.net.Uri
import org.json.JSONObject

/**
 * A decoded Flowbiz push, returned by [Flowbiz.handlePush]. [type] is
 * free-form, so new push kinds need no SDK update; unknown [version]s parse
 * best-effort.
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
    // Not a data class: this raw string stays internal, and [deepLink] is
    // derived lazily so the type is constructible where `android.net.Uri`
    // does not exist (JVM tests).
    internal val deepLinkString: String?,
) {

    /** `deep_link` as a [Uri], or null when absent (`Uri.parse` validates nothing). */
    val deepLink: Uri?
        get() = try {
            deepLinkString?.let(Uri::parse)
        } catch (t: Throwable) {
            null
        }

    /**
     * The cart-recovery payload of [deepLink], if it carries a decodable
     * `_mb_cr_`. Pure: no UTM capture and no tenant check; on tap, call
     * [Flowbiz.handlePushOpened] instead.
     */
    val recoveryPayload: RecoveryPayload?
        get() = RecoveryLinkParser.parse(deepLinkString)
}

/**
 * Decodes the `"flowbiz"` value: a JSON-encoded *string*, since FCM data
 * messages are a flat `Map<String, String>`. Unknown `v` values and fields
 * parse best-effort; null for undecodable JSON or a missing/empty `type`.
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
