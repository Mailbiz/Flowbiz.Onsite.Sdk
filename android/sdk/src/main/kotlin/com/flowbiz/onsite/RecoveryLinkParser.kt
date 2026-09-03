package com.flowbiz.onsite

import org.json.JSONArray
import org.json.JSONObject

/**
 * Pure decoder behind [Flowbiz.handleLink] (SPEC §11): URL string →
 * `_mb_cr_` query value (+ `utm_source` guard) → base64 → hash JSON
 * `{t, u, c, its: [[qty, product_id, sku, recovery_properties?]]}` →
 * [RecoveryPayload]. Mirrors the web tag's `getRecoveryDataFromQuery`.
 *
 * Operates on the raw URL *string* (the facade adapts `android.net.Uri` via
 * `toString()`), for two reasons: `Uri` does not exist in JVM unit tests,
 * and `Uri.getQueryParameter` decodes `+` to a space before callers see it.
 *
 * Encoding tolerance: the value is tried raw, percent-decoded (`%XX` only),
 * and with `' '` restored to `'+'`; missing base64 padding is added;
 * URL-safe `-`/`_` are accepted. First candidate that decodes to a valid
 * payload wins.
 *
 * Tenant check: when `expectedAppId` is given (SDK initialized), `t` must
 * equal it, like web `appId === hash.t`. Before initialize the decoder is
 * pure and skips the check (SPEC §3). Never throws.
 */
internal object RecoveryLinkParser {

    private const val PARAM = "_mb_cr_"
    private const val UTM_PARAM = "utm_source"

    fun parse(url: String?, expectedAppId: String? = null): RecoveryPayload? {
        if (url == null) return null
        return try {
            val pairs = queryPairs(url)
            val raw = pairs.firstOrNull { it.first == PARAM && it.second.isNotEmpty() }?.second ?: return null
            val utm = pairs.firstOrNull { it.first == UTM_PARAM }?.second ?: return null
            if (!isValidUtm(utm)) return null
            val candidates = LinkedHashSet<String>()
            candidates.add(raw.replace(' ', '+'))
            candidates.add(raw)
            percentDecode(raw)?.let { candidates.add(it.replace(' ', '+')); candidates.add(it) }
            for (candidate in candidates) {
                val json = decodeBase64(candidate) ?: continue
                mapHash(json, expectedAppId)?.let { return it }
            }
            null
        } catch (t: Throwable) {
            null
        }
    }

    /**
     * Query pairs in order. Fragment cut first (M2 — spec §7 step 1: a `?`
     * inside the fragment, e.g. `#/cart?_mb_cr_=…`, is not a query), then
     * the query is found within what remains. Keys percent-decoded, values
     * raw.
     */
    private fun queryPairs(url: String): List<Pair<String, String>> {
        val fragmentStart = url.indexOf('#')
        val beforeFragment = if (fragmentStart >= 0) url.substring(0, fragmentStart) else url
        val queryStart = beforeFragment.indexOf('?')
        if (queryStart < 0) return emptyList()
        val query = beforeFragment.substring(queryStart + 1)
        return query.split('&').filter { it.isNotEmpty() }.map { pair ->
            val eq = pair.indexOf('=')
            val key = if (eq >= 0) pair.substring(0, eq) else pair
            val value = if (eq >= 0) pair.substring(eq + 1) else ""
            (percentDecode(key) ?: key) to value
        }
    }

    /** Web `isValidUtm`: contains "mailbiz" or "flowbiz", case-insensitive. */
    private fun isValidUtm(raw: String): Boolean {
        val value = (percentDecode(raw) ?: raw).lowercase()
        return value.contains("mailbiz") || value.contains("flowbiz")
    }

    /** Standard or URL-safe base64, padding optional → UTF-8 string. */
    private fun decodeBase64(value: String): String? = try {
        var normalized = value.replace('-', '+').replace('_', '/')
        val remainder = normalized.length % 4
        if (remainder == 1) {
            null
        } else {
            if (remainder > 0) normalized += "=".repeat(4 - remainder)
            String(java.util.Base64.getDecoder().decode(normalized), Charsets.UTF_8)
        }
    } catch (_: Throwable) {
        null
    }

    /**
     * `%XX` decoding over UTF-8 bytes. Returns null for malformed escapes —
     * the raw candidate then stands on its own.
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

    private fun mapHash(json: String, expectedAppId: String?): RecoveryPayload? = try {
        val hash = JSONObject(json)
        val cartId = nonEmptyString(hash.opt("c"))
        val userId = nonEmptyString(hash.opt("u"))
        val tenant = nonEmptyString(hash.opt("t"))
        val its = hash.optJSONArray("its")
        if (cartId == null || userId == null || tenant == null || its == null || its.length() == 0) {
            null
        } else if (expectedAppId != null && tenant != expectedAppId) {
            SdkLog.debug("recovery link ignored: tenant mismatch")
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
            // `Double.toLong()`/`.toInt()` already saturate out-of-range and
            // infinite values since Kotlin 1.3 (never throws); the explicit
            // `coerceIn` makes that saturation to Int32's range visible in
            // the code path, matching iOS's `parseIntLeading`/`webQuantity`
            // exactly (SPEC §3: never traps).
            is Number -> value.toDouble().takeIf { !it.isNaN() }
                ?.let { it.toLong().coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt() }
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
