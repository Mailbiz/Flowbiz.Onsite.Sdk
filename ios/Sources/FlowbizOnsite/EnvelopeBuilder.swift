import Foundation

enum EnvelopeBuilder {

    /// `2026-07-21T10:00:00.123Z`, by integer math (Hinnant's civil-from-days):
    /// no `DateFormatter`, no Double rounding, locale-independent.
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

    /// Throws only for non-finite numbers in the payload.
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
        sdkVersion: String,
        contextUrl: String? = nil,
        baseUri: String? = nil,
        recoveryUrl: String? = nil,
        utm: String? = nil
    ) throws -> [String: Any] {
        return buildEntry(
            wireName: EventSerializer.wireName(event),
            dataJSON: try EventSerializer.dataJSONString(event, baseUri: baseUri),
            contextUrl: contextUrl,
            baseUri: baseUri,
            recoveryUrl: recoveryUrl,
            utm: utm,
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
        contextUrl: String? = nil,
        baseUri: String? = nil,
        recoveryUrl: String? = nil,
        utm: String? = nil,
        dataJSON: String = "{}"
    ) -> [String: Any] {
        buildEntry(
            wireName: "page.ping",
            dataJSON: dataJSON,
            contextUrl: contextUrl,
            baseUri: baseUri,
            recoveryUrl: recoveryUrl,
            utm: utm,
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

    /// For wire names outside `Event`, such as `push.token.sync`.
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
        sdkVersion: String,
        contextUrl: String? = nil,
        baseUri: String? = nil,
        recoveryUrl: String? = nil,
        utm: String? = nil
    ) -> [String: Any] {
        buildEntry(
            wireName: wireName,
            dataJSON: dataJSON,
            contextUrl: contextUrl,
            baseUri: baseUri,
            recoveryUrl: recoveryUrl,
            utm: utm,
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

    /// `data` and `context.utm` are JSON strings, not nested objects.
    private static func buildEntry(
        wireName: String,
        dataJSON: String,
        contextUrl: String?,
        baseUri: String?,
        recoveryUrl: String?,
        utm: String?,
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
        if let contextUrl, !contextUrl.isEmpty {
            context["url"] = contextUrl
        }
        if let baseUri, !baseUri.isEmpty { context["baseuri"] = baseUri }
        if let recoveryUrl, !recoveryUrl.isEmpty { context["recoveryUrl"] = recoveryUrl }
        if let utm, !utm.isEmpty { context["utm"] = utm }

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
