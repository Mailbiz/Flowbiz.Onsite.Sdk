import Foundation

/// Pure builder for a single SPEC §4 envelope entry.
///
/// No storage and no statics-derived state: every runtime value (hash,
/// timestamps, identity, context) is injected by the caller — later slices
/// provide the real identity store, clock and device info. This keeps the
/// wire shape deterministic and unit-testable.
enum EnvelopeBuilder {

    /// Formats epoch milliseconds as ISO-8601 UTC with milliseconds,
    /// e.g. `2026-07-21T10:00:00.123Z`.
    ///
    /// Pure integer epoch-millis math (Howard Hinnant's civil-from-days
    /// algorithm) — no `DateFormatter` allocation, no Double seconds
    /// round-trip, thread-safe and locale/timezone independent.
    static func isoMillis(_ epochMillis: Int64) -> String {
        let days = floorDiv(epochMillis, 86_400_000)
        let msOfDay = Int(epochMillis - days * 86_400_000)
        let (year, month, day) = civilFromDays(days)
        let hour = msOfDay / 3_600_000
        let minute = msOfDay / 60_000 % 60
        let second = msOfDay / 1000 % 60
        let millis = msOfDay % 1000
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            year, month, day, hour, minute, second, millis
        )
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Days since 1970-01-01 → proleptic Gregorian (year, month, day).
    private static func civilFromDays(_ days: Int64) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let dayOfEra = z - era * 146_097                                        // [0, 146096]
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365 // [0, 399]
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100) // [0, 365]
        let monthIndex = (5 * dayOfYear + 2) / 153                              // [0, 11], March-based
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (Int(year + (month <= 2 ? 1 : 0)), Int(month), Int(day))
    }

    /// Builds one entry of the envelope `data` array (SPEC §4).
    ///
    /// - `identity.user_id` is omitted when `userId` is nil.
    /// - `context.url` is present only for a `.pageView` carrying a screen
    ///   name (`app://<screenName>`); context carries only SPEC §4 fields —
    ///   the screen name itself ships as `page.title` inside `data`.
    /// - `data` is a JSON **string** (the payload serialized separately),
    ///   not a nested object.
    /// - Throws only for non-finite numbers in the payload (see
    ///   ``EventSerializer``); the SPEC §3 never-throw boundary is applied
    ///   at the public API in Slice 4.
    ///
    /// - Parameters:
    ///   - createdAtMillis: wall-clock epoch millis captured at `track()` time
    ///   - sentAtMillis: wall-clock epoch millis of the transmission attempt
    ///   - timezone: UTC offset of the device, e.g. `-03:00`
    ///   - screen: device screen size, e.g. `1170x2532`
    ///   - platform: `android` or `ios` (drives `context.vendor`, `v_tracker`, `v_version`)
    static func build(
        event: Event,
        hash: String,
        createdAtMillis: Int64,
        sentAtMillis: Int64,
        timezone: String,
        userId: String?,
        anonymousId: String,
        sessionId: String,
        visitCount: Int,
        language: String,
        screen: String,
        appId: String,
        platform: String,
        sdkVersion: String
    ) throws -> [String: Any] {
        var contextUrl: String?
        if case .pageView(let screenName, _) = event, let screenName {
            contextUrl = "app://\(screenName)"
        }
        return buildEntry(
            wireName: EventSerializer.wireName(event),
            dataJSON: try EventSerializer.dataJSONString(event),
            contextUrl: contextUrl,
            hash: hash,
            createdAtMillis: createdAtMillis,
            sentAtMillis: sentAtMillis,
            timezone: timezone,
            userId: userId,
            anonymousId: anonymousId,
            sessionId: sessionId,
            visitCount: visitCount,
            language: language,
            screen: screen,
            appId: appId,
            platform: platform,
            sdkVersion: sdkVersion
        )
    }

    /// Builds a SPEC §8 `page.ping` heartbeat entry. Not part of the `Event`
    /// catalog (the heartbeat is automatic, never tracked by the host app).
    /// `dataJSON` defaults to an empty object; the facade passes the
    /// last-tracked screen as `{"page":{"title":...,"url":"app://..."}}`
    /// (web semantics: pings describe the current page). Same shape rules
    /// as `build`; no `context.url`.
    static func buildPing(
        hash: String,
        createdAtMillis: Int64,
        sentAtMillis: Int64,
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
        dataJSON: String = "{}"
    ) -> [String: Any] {
        buildEntry(
            wireName: "page.ping",
            dataJSON: dataJSON,
            contextUrl: nil,
            hash: hash,
            createdAtMillis: createdAtMillis,
            sentAtMillis: sentAtMillis,
            timezone: timezone,
            userId: userId,
            anonymousId: anonymousId,
            sessionId: sessionId,
            visitCount: visitCount,
            language: language,
            screen: screen,
            appId: appId,
            platform: platform,
            sdkVersion: sdkVersion
        )
    }

    /// Builds an entry for an *internal* raw event — a wire name outside the
    /// public `Event` catalog with a pre-rendered `data` JSON string
    /// (SPEC §10.1 `push.token.sync` / `push.token.remove`). Same envelope
    /// shape as `build`; no `context.url`.
    static func buildRaw(
        wireName: String,
        dataJSON: String,
        hash: String,
        createdAtMillis: Int64,
        sentAtMillis: Int64,
        timezone: String,
        userId: String?,
        anonymousId: String,
        sessionId: String,
        visitCount: Int,
        language: String,
        screen: String,
        appId: String,
        platform: String,
        sdkVersion: String
    ) -> [String: Any] {
        buildEntry(
            wireName: wireName,
            dataJSON: dataJSON,
            contextUrl: nil,
            hash: hash,
            createdAtMillis: createdAtMillis,
            sentAtMillis: sentAtMillis,
            timezone: timezone,
            userId: userId,
            anonymousId: anonymousId,
            sessionId: sessionId,
            visitCount: visitCount,
            language: language,
            screen: screen,
            appId: appId,
            platform: platform,
            sdkVersion: sdkVersion
        )
    }

    private static func buildEntry(
        wireName: String,
        dataJSON: String,
        contextUrl: String?,
        hash: String,
        createdAtMillis: Int64,
        sentAtMillis: Int64,
        timezone: String,
        userId: String?,
        anonymousId: String,
        sessionId: String,
        visitCount: Int,
        language: String,
        screen: String,
        appId: String,
        platform: String,
        sdkVersion: String
    ) -> [String: Any] {
        let vendor = "flowbiz-\(platform)-sdk"

        let timings: [String: Any] = [
            "created_at": isoMillis(createdAtMillis),
            "sent_at": isoMillis(sentAtMillis),
            "timezone": timezone,
        ]

        var identity: [String: Any] = [
            "anonymous_id": anonymousId,
            "session_id": sessionId,
            "visit_count": visitCount,
        ]
        if let userId { identity["user_id"] = userId }

        var context: [String: Any] = [
            "platform": platform,
            "language": language,
            "screen": screen,
            "vendor": vendor,
            "onsite_version": sdkVersion,
        ]
        if let contextUrl {
            context["url"] = contextUrl
        }

        return [
            "event": wireName,
            "hash": hash,
            "data": dataJSON,
            "timings": timings,
            "identity": identity,
            "context": context,
            "app_id": appId,
            "platform": platform,
            "v_tracker": vendor,
            "v_version": "\(platform)-\(sdkVersion)",
        ]
    }
}
