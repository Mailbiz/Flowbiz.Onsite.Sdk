package br.com.flowbiz.onsite

import org.json.JSONArray
import java.util.Locale

/**
 * Persistence cell for the captured UTMs (SPEC §11.1 item 3) — the mobile
 * counterpart of the web's `tracker_u_<appId>` storage, per appId through
 * the appId-scoped [KeyValueStore]:
 *
 * - [StorageKeys.UTM_DATA]: the merged set as a JSON array of
 *   `[key, value]` string pairs in merge order;
 * - [StorageKeys.UTM_EXPIRES_AT_WALL_MS]: now + [TTL_MS] on the wall clock,
 *   rewritten by every [save] — the web's sliding 30-day expiry. Wall time
 *   because the expiry must survive process restarts; like the web, a
 *   clock change is not special-cased.
 *
 * ## Reading (never throws)
 * - Both keys absent → empty. (A value of the wrong type reads as absent
 *   through [KeyValueStore]; the next [save] overwrites it.)
 * - Expired — valid only while `expires − now > 0`, so `now == expires` is
 *   expired (web `StorageFactory`) → **both** keys removed, empty.
 * - Corrupt — one key without the other, not strict JSON, not an array
 *   of 2-string arrays, a key outside [UtmLinkParser.ALLOWLIST], an empty
 *   value, a duplicate key, or an empty array: shapes the SDK never writes
 *   → both keys removed, empty (SPEC §3: discarded silently).
 * - Removal logs `stored utm discarded: expired|corrupt` — the reason
 *   only, never the stored data (SPEC §12); same string as iOS.
 *
 * ## Disabled-state purge
 * While the SDK is opted out (SPEC §11.1 item 4, §12) stored UTMs are
 * neither read nor refreshed; [purgeIfExpired] only enforces the 30 days:
 * it reads nothing but [StorageKeys.UTM_EXPIRES_AT_WALL_MS] and, once that
 * has passed (same boundary as [load]), removes both keys. `utm_data` is
 * never read, so a corrupt one is left for the first read after re-enabling.
 *
 * ## Strict reader (decision)
 * `utm_data` is read by [PairsReader], a strict RFC 8259 reader for exactly
 * the stored shape, not by org.json: org.json is lenient — trailing text,
 * unquoted or single-quoted strings, `;` separators and a stray `]` all
 * parse — and the copy built into ART is not the Maven one the JVM tests
 * run. Strict JSON gives any stored text the same verdict on the JVM, on
 * ART and in the iOS store's `JSONDecoder`: every well-formed JSON text of
 * the shape reads (whitespace, `\/`, either hex case, raw non-ASCII),
 * nothing else does. One intended difference: an escaped lone surrogate
 * (`\ud800`) reads here — it is how [save] writes a lone-surrogate value,
 * which a Kotlin string can hold and a Swift string cannot.
 *
 * ## ASCII-only persistence (decision)
 * `utm_data` is written with every character outside printable ASCII as a
 * JSON `\uXXXX` escape. The values come from arbitrary links, and a decoded
 * `%EF%BF%BE` is a raw U+FFFE — a character XML 1.0 cannot carry, while
 * SharedPreferences persists as an XML file whose failed parse would lose
 * every SDK key in it. Escaping is JSON-equivalent (the parsed pairs are
 * identical), so it costs nothing but bytes.
 *
 * Scheduler-confined: used from [FlowbizCore]'s UTM load and evaluation only.
 */
internal class UtmStore(
    private val store: KeyValueStore,
    private val clock: Clock,
) {

    /** The stored merged set, or empty when missing, expired or corrupt (see class doc). */
    fun load(): List<Pair<String, String>> {
        val data = store.getString(StorageKeys.UTM_DATA)
        val expiresAt = store.getLong(StorageKeys.UTM_EXPIRES_AT_WALL_MS)
        if (data == null && expiresAt == null) return emptyList()
        if (data == null || expiresAt == null) return discard("corrupt")
        // `expires − now > 0`, compared without the subtraction so a corrupt
        // extreme value cannot overflow into "valid".
        if (expiresAt <= clock.wallMillis()) return discard("expired")
        return parse(data) ?: discard("corrupt")
    }

    /**
     * The disabled-state purge (see class doc): removes both keys when the
     * stored expiry has passed; no expiry, a live one or a wrong-typed one
     * (reads as absent) leaves the store untouched. Never throws.
     */
    fun purgeIfExpired() {
        try {
            val expiresAt = store.getLong(StorageKeys.UTM_EXPIRES_AT_WALL_MS) ?: return
            if (expiresAt <= clock.wallMillis()) discard("expired")
        } catch (t: Throwable) {
            SdkLog.debug("stored utm purge failed: ${t.javaClass.simpleName}")
        }
    }

    /**
     * Persists [pairs] (non-empty, distinct allowlisted keys) and slides the
     * expiry to now + [TTL_MS] — saturating at `Long.MAX_VALUE` rather than
     * wrapping into an already-expired past (the iOS store saturates too).
     */
    fun save(pairs: List<Pair<String, String>>) {
        val array = JSONArray()
        for ((key, value) in pairs) array.put(JSONArray().put(key).put(value))
        val now = clock.wallMillis()
        val expiresAt = if (now > Long.MAX_VALUE - TTL_MS) Long.MAX_VALUE else now + TTL_MS
        store.putString(StorageKeys.UTM_DATA, asciiOnly(CanonicalJson.render(array)))
        store.putLong(StorageKeys.UTM_EXPIRES_AT_WALL_MS, expiresAt)
    }

    private fun discard(reason: String): List<Pair<String, String>> {
        store.remove(StorageKeys.UTM_DATA)
        store.remove(StorageKeys.UTM_EXPIRES_AT_WALL_MS)
        SdkLog.debug("stored utm discarded: $reason")
        return emptyList()
    }

    private fun parse(data: String): List<Pair<String, String>>? {
        return try {
            val rows = PairsReader(data).read() ?: return null
            if (rows.isEmpty()) return null
            val pairs = ArrayList<Pair<String, String>>(rows.size)
            for ((key, value) in rows) {
                if (key !in UtmLinkParser.ALLOWLIST || value.isEmpty()) return null
                if (pairs.any { it.first == key }) return null
                pairs += key to value
            }
            pairs
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Escapes every character outside printable ASCII in already-canonical
     * JSON text as `\uXXXX` (one escape per UTF-16 unit, surrogate pairs
     * included). Canonical JSON keeps such characters only inside string
     * literals — structure is ASCII — so the result parses to the same
     * value.
     */
    private fun asciiOnly(json: String): String {
        if (json.all { it.code in 0x20..0x7e }) return json
        return buildString(json.length + 16) {
            for (c in json) {
                if (c.code in 0x20..0x7e) append(c) else append(String.format(Locale.ROOT, "\\u%04x", c.code))
            }
        }
    }

    /**
     * Strict RFC 8259 reader for exactly `[[string, string], …]` (see
     * "Strict reader" in the class doc): [read] returns the rows in order —
     * possibly none — or null for any text that is not one such JSON array
     * with only whitespace around it. Strings admit no raw control
     * character and only the JSON escapes (`\uXXXX` in either hex case);
     * shape errors (a row of another length, a non-string) are null too.
     */
    private class PairsReader(private val text: String) {
        private var index = 0

        fun read(): List<Pair<String, String>>? {
            if (!accept('[')) return null
            val rows = ArrayList<Pair<String, String>>()
            if (!accept(']')) {
                do {
                    if (!accept('[')) return null
                    val key = string() ?: return null
                    if (!accept(',')) return null
                    val value = string() ?: return null
                    if (!accept(']')) return null
                    rows += key to value
                } while (accept(','))
                if (!accept(']')) return null
            }
            skipWhitespace()
            return if (index == text.length) rows else null
        }

        /** Skips JSON whitespace, then consumes [char] when it comes next. */
        private fun accept(char: Char): Boolean {
            skipWhitespace()
            if (index >= text.length || text[index] != char) return false
            index++
            return true
        }

        private fun skipWhitespace() {
            while (index < text.length && text[index].let { it == ' ' || it == '\t' || it == '\n' || it == '\r' }) index++
        }

        private fun string(): String? {
            if (!accept('"')) return null
            val out = StringBuilder()
            while (index < text.length) {
                val c = text[index++]
                when {
                    c == '"' -> return out.toString()
                    c < ' ' -> return null
                    c != '\\' -> out.append(c)
                    index >= text.length -> return null
                    else -> when (text[index++]) {
                        '"' -> out.append('"')
                        '\\' -> out.append('\\')
                        '/' -> out.append('/')
                        'b' -> out.append('\b')
                        'f' -> out.append('\u000C')
                        'n' -> out.append('\n')
                        'r' -> out.append('\r')
                        't' -> out.append('\t')
                        'u' -> out.append(unicodeEscape() ?: return null)
                        else -> return null
                    }
                }
            }
            return null // unterminated
        }

        /**
         * The four ASCII hex digits after `\u` as one UTF-16 unit (a pair's
         * halves come as two escapes). Not `Character.digit`, which also
         * takes fullwidth and other Unicode digits.
         */
        private fun unicodeEscape(): Char? {
            if (index + 4 > text.length) return null
            var code = 0
            repeat(4) {
                val digit = when (val hex = text[index++]) {
                    in '0'..'9' -> hex - '0'
                    in 'a'..'f' -> hex - 'a' + 10
                    in 'A'..'F' -> hex - 'A' + 10
                    else -> return null
                }
                code = (code shl 4) or digit
            }
            return code.toChar()
        }
    }

    companion object {
        /** 30 days in milliseconds — the web's `thirtyDays * 1000` UTM storage TTL. */
        const val TTL_MS: Long = 30L * 24L * 60L * 60L * 1000L
    }
}
