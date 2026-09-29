package br.com.flowbiz.onsite

import org.json.JSONObject
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** Pure builder for one envelope entry: every runtime value is injected by the caller. */
internal object EnvelopeBuilder {

    private val ISO_MILLIS_UTC: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

    fun isoMillis(epochMillis: Long): String = ISO_MILLIS_UTC.format(Instant.ofEpochMilli(epochMillis))

    /**
     * `data` and `context.utm` are JSON **strings**, as the web sends them,
     * not nested objects; null or empty optional fields are omitted. Throws
     * only for non-finite numbers in the payload.
     */
    fun build(
        event: Event,
        hash: String,
        createdAtMillis: Long,
        sentAtMillis: Long,
        timezone: String,
        userId: String?,
        anonymousId: String,
        sessionId: String,
        visitCount: Int,
        language: String,
        screen: String,
        appId: String,
        platform: String,
        sdkVersion: String,
        contextUrl: String? = null,
        baseUri: String? = null,
        recoveryUrl: String? = null,
        utm: String? = null,
    ): JSONObject = buildEntry(
        wireName = EventSerializer.wireName(event),
        dataJson = EventSerializer.dataJson(event, baseUri),
        contextUrl = contextUrl,
        baseUri = baseUri,
        recoveryUrl = recoveryUrl,
        utm = utm,
        hash = hash,
        createdAtMillis = createdAtMillis,
        sentAtMillis = sentAtMillis,
        timezone = timezone,
        userId = userId,
        anonymousId = anonymousId,
        sessionId = sessionId,
        visitCount = visitCount,
        language = language,
        screen = screen,
        appId = appId,
        platform = platform,
        sdkVersion = sdkVersion,
    )

    /** A `page.ping` entry: the heartbeat is automatic, never an [Event] tracked by the app. */
    fun buildPing(
        hash: String,
        createdAtMillis: Long,
        sentAtMillis: Long,
        timezone: String,
        userId: String?,
        anonymousId: String,
        sessionId: String,
        visitCount: Int,
        language: String,
        screen: String,
        appId: String,
        platform: String,
        sdkVersion: String,
        contextUrl: String? = null,
        baseUri: String? = null,
        recoveryUrl: String? = null,
        utm: String? = null,
        dataJson: String = "{}",
    ): JSONObject = buildEntry(
        wireName = "page.ping",
        dataJson = dataJson,
        contextUrl = contextUrl,
        baseUri = baseUri,
        recoveryUrl = recoveryUrl,
        utm = utm,
        hash = hash,
        createdAtMillis = createdAtMillis,
        sentAtMillis = sentAtMillis,
        timezone = timezone,
        userId = userId,
        anonymousId = anonymousId,
        sessionId = sessionId,
        visitCount = visitCount,
        language = language,
        screen = screen,
        appId = appId,
        platform = platform,
        sdkVersion = sdkVersion,
    )

    /** An entry for an internal wire event outside the public [Event] catalog (`push.token.*`). */
    fun buildRaw(
        wireName: String,
        dataJson: String,
        hash: String,
        createdAtMillis: Long,
        sentAtMillis: Long,
        timezone: String,
        userId: String?,
        anonymousId: String,
        sessionId: String,
        visitCount: Int,
        language: String,
        screen: String,
        appId: String,
        platform: String,
        sdkVersion: String,
        contextUrl: String? = null,
        baseUri: String? = null,
        recoveryUrl: String? = null,
        utm: String? = null,
    ): JSONObject = buildEntry(
        wireName = wireName,
        dataJson = dataJson,
        contextUrl = contextUrl,
        baseUri = baseUri,
        recoveryUrl = recoveryUrl,
        utm = utm,
        hash = hash,
        createdAtMillis = createdAtMillis,
        sentAtMillis = sentAtMillis,
        timezone = timezone,
        userId = userId,
        anonymousId = anonymousId,
        sessionId = sessionId,
        visitCount = visitCount,
        language = language,
        screen = screen,
        appId = appId,
        platform = platform,
        sdkVersion = sdkVersion,
    )

    private fun buildEntry(
        wireName: String,
        dataJson: String,
        contextUrl: String?,
        baseUri: String?,
        recoveryUrl: String?,
        utm: String?,
        hash: String,
        createdAtMillis: Long,
        sentAtMillis: Long,
        timezone: String,
        userId: String?,
        anonymousId: String,
        sessionId: String,
        visitCount: Int,
        language: String,
        screen: String,
        appId: String,
        platform: String,
        sdkVersion: String,
    ): JSONObject {
        val vendor = "flowbiz-$platform-sdk"

        val timings = JSONObject()
            .put("created_at", isoMillis(createdAtMillis))
            .put("sent_at", isoMillis(sentAtMillis))
            .put("timezone", timezone)

        val identity = JSONObject()
        if (userId != null) identity.put("user_id", userId)
        identity
            .put("anonymous_id", anonymousId)
            .put("session_id", sessionId)
            .put("visit_count", visitCount)

        val context = JSONObject()
            .put("platform", platform)
            .put("language", language)
            .put("screen", screen)
            .put("vendor", vendor)
            .put("onsite_version", sdkVersion)
        if (!contextUrl.isNullOrEmpty()) {
            context.put("url", contextUrl)
        }
        if (!baseUri.isNullOrEmpty()) context.put("baseuri", baseUri)
        if (!recoveryUrl.isNullOrEmpty()) context.put("recoveryUrl", recoveryUrl)
        if (!utm.isNullOrEmpty()) context.put("utm", utm)

        return JSONObject()
            .put("event", wireName)
            .put("hash", hash)
            .put("data", dataJson)
            .put("timings", timings)
            .put("identity", identity)
            .put("context", context)
            .put("app_id", appId)
            .put("platform", platform)
            .put("v_tracker", vendor)
            .put("v_version", "$platform-$sdkVersion")
    }
}
