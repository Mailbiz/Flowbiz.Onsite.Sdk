package com.flowbiz.onsite

import org.json.JSONObject
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * Pure builder for a single SPEC §4 envelope entry.
 *
 * No storage and no statics-derived state: every runtime value (hash,
 * timestamps, identity, context) is injected by the caller — later slices
 * provide the real identity store, clock and device info. This keeps the
 * wire shape deterministic and unit-testable.
 */
internal object EnvelopeBuilder {

    private val ISO_MILLIS_UTC: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

    /** Formats epoch milliseconds as ISO-8601 UTC with milliseconds, e.g. `2026-07-21T10:00:00.123Z`. */
    fun isoMillis(epochMillis: Long): String = ISO_MILLIS_UTC.format(Instant.ofEpochMilli(epochMillis))

    /**
     * Builds one entry of the envelope `data` array (SPEC §4).
     *
     * - `identity.user_id` is omitted when [userId] is null.
     * - `context.url` is present only for a [Event.PageView] carrying a
     *   screen name (`app://<screenName>`); context carries only SPEC §4
     *   fields — the screen name itself ships as `page.title` inside `data`.
     * - `data` is a JSON **string** (the payload serialized separately),
     *   not a nested object.
     * - Throws only for non-finite numbers in the payload (see
     *   [EventSerializer]); the SPEC §3 never-throw boundary is applied at
     *   the public API in Slice 4.
     *
     * @param createdAtMillis wall-clock epoch millis captured at `track()` time
     * @param sentAtMillis wall-clock epoch millis of the transmission attempt
     * @param timezone UTC offset of the device, e.g. `-03:00`
     * @param screen device screen size, e.g. `1080x2400`
     * @param platform `android` or `ios` (drives `context.vendor`, `v_tracker`, `v_version`)
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
    ): JSONObject = buildEntry(
        wireName = EventSerializer.wireName(event),
        dataJson = EventSerializer.dataJson(event),
        contextUrl = (event as? Event.PageView)?.screenName?.let { "app://$it" },
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

    /**
     * Builds a SPEC §8 `page.ping` heartbeat entry. Not part of the [Event]
     * catalog (the heartbeat is automatic, never tracked by the host app).
     * [dataJson] defaults to an empty object; the facade passes the
     * last-tracked screen as `{"page":{"title":...,"url":"app://..."}}`
     * (web semantics: pings describe the current page). Same shape rules as
     * [build]; no `context.url`.
     */
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
        dataJson: String = "{}",
    ): JSONObject = buildEntry(
        wireName = "page.ping",
        dataJson = dataJson,
        contextUrl = null,
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
        if (contextUrl != null) {
            context.put("url", contextUrl)
        }

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
