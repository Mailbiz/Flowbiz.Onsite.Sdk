package br.com.flowbiz.onsite

import android.net.Uri
import org.json.JSONObject

class FlowbizPush internal constructor(
    /** Contract version (`v`); 1 when absent or malformed. */
    val version: Int,
    /** Free-form push kind; never empty. */
    val type: String,
    val title: String?,
    val body: String?,
    val data: Map<String, Any?>,
    // A string, with deepLink derived: JVM tests construct pushes where android.net.Uri does not exist.
    internal val deepLinkString: String?,
) {

    val deepLink: Uri?
        get() = try {
            deepLinkString?.let(Uri::parse)
        } catch (t: Throwable) {
            null
        }

    /** Pure decode (no UTM capture, no tenant check); on tap, call [Flowbiz.handlePushOpened] instead. */
    val recoveryPayload: RecoveryPayload?
        get() = RecoveryLinkParser.parse(deepLinkString)
}

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
