package com.flowbiz.onsite

import org.json.JSONArray
import org.json.JSONObject

/**
 * Pure decoder behind [Flowbiz.handleLink] (SPEC §11): URL string →
 * `mb_recovery` query value → LZ-string decompress → hash JSON
 * `{t, u, c, its: [[qty, product_id, sku, recovery_properties?]]}` →
 * [RecoveryPayload].
 *
 * Operates on the raw URL *string* (the facade adapts `android.net.Uri` via
 * `toString()`), for two reasons: `Uri` does not exist in JVM unit tests,
 * and `Uri.getQueryParameter` decodes `+` to a space — hostile to a value
 * whose alphabet includes `+`.
 *
 * ## Percent-encoding tolerance
 * The compressed value's alphabet (`A-Za-z0-9+-$`) is URL-safe by design,
 * so the web puts the hash in links *unencoded* — but intermediate link
 * handling may percent-encode (`+` → `%2B`, `$` → `%24`) or turn `+` into a
 * space. The parser tries the raw value first (the decompressor itself
 * restores `" "` → `"+"`, reference behavior), then a percent-decoded
 * variant (decoding `%XX` only — never `+` → space). First candidate that
 * decodes to a valid payload wins.
 *
 * ## Hash → payload mapping (web `buildCartRecoveryPayload` parity)
 * - `t`, `u`, `c` must be present and non-empty, `its` a non-empty array —
 *   else the whole payload is null (web `getRecoveryDataFromQuery`
 *   validation). `t` (tenant) is *not* compared against the SDK config:
 *   `handleLink` is pure and callable before `initialize` (SPEC §3).
 * - per item: `product_id`/`sku` from index 1/2 (missing → `""`), quantity
 *   `parseInt(it[0]) || 1`, `recovery_properties` from index 3 (JSON-object
 *   string; garbage → null). Non-array `its` elements are skipped (the JS
 *   would string-index them into garbage — not emulated).
 *
 * Pure, synchronous, never throws.
 */
internal object RecoveryLinkParser {

    private const val PARAM = "mb_recovery"

    fun parse(url: String?): RecoveryPayload? {
        if (url == null) return null
        return try {
            val raw = queryParameter(url) ?: return null
            val candidates = LinkedHashSet<String>()
            candidates.add(raw)
            percentDecode(raw)?.let { candidates.add(it) }
            for (candidate in candidates) {
                val json = LZString.decompressFromEncodedURIComponent(candidate) ?: continue
                mapHash(json)?.let { return it }
            }
            null
        } catch (t: Throwable) {
            // SPEC §3 never-throw: any surprise degrades to "not a recovery link".
            null
        }
    }

    /** Raw (undecoded) value of the first `mb_recovery` pair in the query string. */
    private fun queryParameter(url: String): String? {
        val queryStart = url.indexOf('?')
        if (queryStart < 0) return null
        var query = url.substring(queryStart + 1)
        val fragmentStart = query.indexOf('#')
        if (fragmentStart >= 0) query = query.substring(0, fragmentStart)
        for (pair in query.split('&')) {
            val eq = pair.indexOf('=')
            val key = if (eq >= 0) pair.substring(0, eq) else pair
            if (key == PARAM || percentDecode(key) == PARAM) {
                val value = if (eq >= 0) pair.substring(eq + 1) else ""
                if (value.isNotEmpty()) return value
            }
        }
        return null
    }

    /**
     * `%XX` decoding over UTF-8 bytes. Deliberately does NOT decode `+` to a
     * space (the LZ alphabet contains `+`). Returns null for malformed
     * escapes — the raw candidate then stands on its own.
     */
    private fun percentDecode(value: String): String? {
        if ('%' !in value) return value
        val bytes = ArrayList<Byte>(value.length)
        var i = 0
        while (i < value.length) {
            val char = value[i]
            if (char == '%') {
                if (i + 2 >= value.length) return null
                val high = hexDigit(value[i + 1]) ?: return null
                val low = hexDigit(value[i + 2]) ?: return null
                bytes.add(((high shl 4) or low).toByte())
                i += 3
            } else {
                for (byte in char.toString().toByteArray(Charsets.UTF_8)) bytes.add(byte)
                i += 1
            }
        }
        return String(bytes.toByteArray(), Charsets.UTF_8)
    }

    private fun hexDigit(char: Char): Int? = when (char) {
        in '0'..'9' -> char - '0'
        in 'a'..'f' -> char - 'a' + 10
        in 'A'..'F' -> char - 'A' + 10
        else -> null
    }

    // MARK: hash → payload

    private fun mapHash(json: String): RecoveryPayload? = try {
        val hash = JSONObject(json)
        val cartId = nonEmptyString(hash.opt("c"))
        val userId = nonEmptyString(hash.opt("u"))
        val tenant = nonEmptyString(hash.opt("t"))
        val its = hash.optJSONArray("its")
        if (cartId == null || userId == null || tenant == null || its == null || its.length() == 0) {
            null
        } else {
            val products = ArrayList<RecoveryProduct>(its.length())
            for (i in 0 until its.length()) {
                val item = its.optJSONArray(i) ?: continue
                products.add(
                    RecoveryProduct(
                        productId = itemString(item, 1),
                        sku = itemString(item, 2),
                        quantity = webQuantity(item.opt(0)),
                        recoveryProperties = recoveryProperties(item.opt(3)),
                    )
                )
            }
            if (products.isEmpty()) null else RecoveryPayload(cartId, userId, products)
        }
    } catch (t: Throwable) {
        null
    }

    private fun nonEmptyString(value: Any?): String? = when (value) {
        is String -> value.takeIf { it.isNotEmpty() }
        // A numeric id passes through the JS untouched; stringified here to
        // fit the typed payload.
        is Number, is Boolean -> value.toString()
        else -> null
    }

    /** Web `it[idx] || ''`: missing/null/empty → `""`; numbers stringified. */
    private fun itemString(item: JSONArray, index: Int): String = when (val value = item.opt(index)) {
        is String -> value
        null, JSONObject.NULL -> ""
        is Number, is Boolean -> value.toString()
        else -> ""
    }

    /**
     * Web `parseInt(it[0]) || 1`: leading decimal integer of a string (JS
     * `parseInt` semantics — leading whitespace/sign, trailing junk
     * ignored), numbers truncated toward zero; `NaN` *and* `0` (falsy) → 1.
     */
    private fun webQuantity(value: Any?): Int {
        val parsed: Int? = when (value) {
            is Number -> value.toDouble().takeIf { !it.isNaN() }?.toInt()
            is String -> parseIntLeading(value)
            else -> null
        }
        return if (parsed == null || parsed == 0) 1 else parsed
    }

    private fun parseIntLeading(value: String): Int? {
        val trimmed = value.trim()
        var i = 0
        var sign = 1L
        if (i < trimmed.length && (trimmed[i] == '+' || trimmed[i] == '-')) {
            if (trimmed[i] == '-') sign = -1L
            i++
        }
        var digits = 0
        var accumulated = 0L
        while (i < trimmed.length && trimmed[i] in '0'..'9') {
            if (digits < 12) { // beyond any realistic quantity; avoids overflow
                accumulated = accumulated * 10 + (trimmed[i] - '0')
            }
            digits++
            i++
        }
        if (digits == 0) return null
        return (sign * accumulated).coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()
    }

    /**
     * 4th `its` element → properties map. Web parity: a JSON-object *string*
     * (`tryToParseJson`); a nested object is additionally tolerated. Garbage
     * → null (web emits `{}` — same meaning).
     */
    private fun recoveryProperties(value: Any?): Map<String, Any?>? = try {
        when (value) {
            is String -> if (value.isEmpty()) null else JsonPlain.toPlainMap(JSONObject(value))
            is JSONObject -> JsonPlain.toPlainMap(value)
            else -> null
        }
    } catch (t: Throwable) {
        null
    }
}
