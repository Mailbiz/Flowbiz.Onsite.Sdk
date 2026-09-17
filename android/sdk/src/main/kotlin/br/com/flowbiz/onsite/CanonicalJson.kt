package br.com.flowbiz.onsite

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import kotlin.math.abs

/**
 * Canonical JSON writer for the wire `data` payload strings (SPEC §4/§5).
 *
 * org.json's own `toString()` diverges from the web tracker's
 * `JSON.stringify` (the reference implementation): `1.0E7`-style exponents
 * for large doubles (JVM), `-0` for negative zero, `\u2014`-style escaping
 * of U+2000–U+20FF characters, and `<\/` slash escaping. This writer emits
 * the canonical cross-platform form instead:
 *
 * - **numbers**: `Double.toString` digits formatted with the ECMAScript
 *   `Number::toString` layout rules — `19.99`, `0.1`, whole doubles without
 *   a fraction part (`19.0` → `19`), fixed notation up to 21 digits
 *   (`10000000`, not `1.0E7`), exponent form beyond (`1e+21`), `-0.0` → `0`.
 *   Caveat: on JDK ≤ 18 (Android included) `Double.toString` is *not*
 *   guaranteed shortest-round-trip (JDK-4511638, fixed in JDK 19), so a few
 *   extreme magnitudes carry extra digits vs JS/Swift — e.g. `1e23` renders
 *   `9.999999999999999e+22` (JS: `1e+23`) and `5e-324` renders `4.9e-324`
 *   (JS: `5e-324`). Both parse back to the identical double; realistic
 *   payload values (prices, quantities) are unaffected. Pinned by
 *   `CanonicalJsonNumberTest`.
 * - **strings**: minimal escaping — only `"` `\` and control characters;
 *   raw slashes, raw unicode
 * - **objects**: keys sorted by UTF-16 code units (deterministic output;
 *   matches Swift's UTF-16 sort and JS `Array.prototype.sort`)
 *
 * Mirrored by the Swift `CanonicalJSON`; both are pinned byte-for-byte by
 * `expected.data_canonical` in `shared/fixtures/`.
 *
 * **Throws** on non-finite numbers (NaN/±Infinity) — the same contract as
 * the Swift serializer (org.json already rejects non-finite doubles with a
 * `JSONException` at tree-build time; [numberToJson] re-checks). The SPEC §3
 * never-throw guarantee is applied at the public API boundary (Slice 4),
 * not here.
 */
internal object CanonicalJson {

    /** Renders an org.json tree as a compact canonical string. */
    fun render(value: Any?): String = buildString { appendValue(this, value) }

    private fun appendValue(out: StringBuilder, value: Any?) {
        when {
            value == null || value === JSONObject.NULL -> out.append("null")
            value is String -> appendString(out, value)
            value is Boolean -> out.append(if (value) "true" else "false")
            value is Int || value is Long -> out.append(value.toString())
            // Double/Float and org.json's parsed BigDecimals: all treated as
            // doubles, matching iOS (`JSONValue.number(Double)`) and JS.
            value is Number -> out.append(numberToJson(value.toDouble()))
            value is JSONObject -> {
                out.append('{')
                val keys = buildList {
                    val iterator = value.keys()
                    while (iterator.hasNext()) add(iterator.next() as String)
                }.sorted()
                keys.forEachIndexed { index, key ->
                    if (index > 0) out.append(',')
                    appendString(out, key)
                    out.append(':')
                    appendValue(out, value.get(key))
                }
                out.append('}')
            }
            value is JSONArray -> {
                out.append('[')
                for (index in 0 until value.length()) {
                    if (index > 0) out.append(',')
                    appendValue(out, value.get(index))
                }
                out.append(']')
            }
            else -> throw IllegalArgumentException("unsupported JSON value of type ${value::class.java.name}")
        }
    }

    // --- Strings ---

    /**
     * Minimal escaping, matching `JSON.stringify`: `"` and `\` plus control
     * characters (and lone surrogates, per well-formed `JSON.stringify`);
     * everything else — slashes, unicode — is emitted raw.
     */
    private fun appendString(out: StringBuilder, value: String) {
        out.append('"')
        var i = 0
        while (i < value.length) {
            val c = value[i]
            when {
                c == '"' -> out.append("\\\"")
                c == '\\' -> out.append("\\\\")
                c == '\b' -> out.append("\\b")
                c == '\t' -> out.append("\\t")
                c == '\n' -> out.append("\\n")
                c == '\u000C' -> out.append("\\f")
                c == '\r' -> out.append("\\r")
                c < ' ' -> out.append(String.format(Locale.ROOT, "\\u%04x", c.code))
                c.isHighSurrogate() && i + 1 < value.length && value[i + 1].isLowSurrogate() -> {
                    out.append(c).append(value[i + 1])
                    i++
                }
                c.isSurrogate() -> out.append(String.format(Locale.ROOT, "\\u%04x", c.code))
                else -> out.append(c)
            }
            i++
        }
        out.append('"')
    }

    // --- Numbers ---

    /**
     * ECMAScript `Number::toString(10)` rendering of a finite double, built
     * from Java's `Double.toString` digits (shortest round-trip only from
     * JDK 19; see the class doc for the JDK-4511638 caveat).
     */
    fun numberToJson(value: Double): String {
        require(!value.isNaN() && !value.isInfinite()) {
            "JSON does not allow non-finite numbers ($value)"
        }
        if (value == 0.0) return "0" // covers -0.0 → "0" (JSON.stringify(-0))

        // Parse the shortest representation, e.g. "19.99", "19.0", "1.0E21",
        // "1.0E-7", into sign + digit string + decimal exponent.
        var repr = value.toString()
        var sign = ""
        if (repr.startsWith("-")) {
            sign = "-"
            repr = repr.substring(1)
        }
        val eIndex = repr.indexOfFirst { it == 'e' || it == 'E' }
        var mantissa = repr
        var exp10 = 0
        if (eIndex >= 0) {
            mantissa = repr.substring(0, eIndex)
            exp10 = repr.substring(eIndex + 1).toInt()
        }
        val dotIndex = mantissa.indexOf('.')
        val rawDigits = if (dotIndex >= 0) mantissa.removeRange(dotIndex, dotIndex + 1) else mantissa
        // `n` per ECMA-262 Number::toString: value == 0.digits × 10^n.
        var n = (if (dotIndex >= 0) dotIndex else mantissa.length) + exp10
        var start = 0
        while (start < rawDigits.length - 1 && rawDigits[start] == '0') {
            start++
            n--
        }
        var end = rawDigits.length
        while (end - start > 1 && rawDigits[end - 1] == '0') end--
        val digits = rawDigits.substring(start, end)
        val k = digits.length

        return when {
            n in k..21 -> sign + digits + "0".repeat(n - k)
            n in 1..21 -> sign + digits.substring(0, n) + "." + digits.substring(n)
            n in -5..0 -> sign + "0." + "0".repeat(-n) + digits
            else -> {
                val exponent = n - 1
                val head = if (k == 1) digits else digits[0] + "." + digits.substring(1)
                sign + head + "e" + (if (exponent >= 0) "+" else "-") + abs(exponent)
            }
        }
    }
}
