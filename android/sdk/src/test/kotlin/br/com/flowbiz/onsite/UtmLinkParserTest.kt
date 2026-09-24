package br.com.flowbiz.onsite

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import kotlin.random.Random

/**
 * UTM ingestion (SPEC §11.1): [UtmLinkParser] pinned byte-for-byte to the
 * web tag by `shared/utm-links/vectors.json`, which `generate.mts` produces
 * by running the web's own `Url.getQueryParameters` +
 * `setUtmNavigationContext` — `expected` is the exact `context.utm` string,
 * or null when web never calls `setUtmData` (no `utm` key on the wire).
 */
class UtmLinkParserTest {

    private val vectors: JSONObject by lazy { FixtureSupport.utmLinkVectors() }

    private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

    private fun JSONObject.stringOrNull(key: String): String? = if (isNull(key)) null else getString(key)

    /** The `context.utm` of a merged set: its rendering, or null (no `utm` key) when it is empty. */
    private fun contextUtm(merged: List<Pair<String, String>>): String? =
        if (merged.isEmpty()) null else UtmLinkParser.render(merged)

    // --- Shared vectors (the drift guard) ---

    @Test
    fun everyExtractVectorRendersTheWebContextUtmExactly() {
        val extract = vectors.getJSONArray("extract").objects()
        assertTrue("truncated vectors.json: ${extract.size} extract vectors", extract.size >= 60)
        for (vector in extract) {
            val name = vector.getString("name")
            val merged = UtmLinkParser.merge(emptyList(), UtmLinkParser.extract(vector.getString("url")))
            assertEquals(name, vector.stringOrNull("expected"), contextUtm(merged))
        }
    }

    @Test
    fun everySequenceCarriesTheMergedSetFromStepToStep() {
        val sequences = vectors.getJSONArray("sequences").objects()
        assertTrue("truncated vectors.json: ${sequences.size} sequences", sequences.size >= 4)
        for (sequence in sequences) {
            val name = sequence.getString("name")
            var stored = emptyList<Pair<String, String>>()
            sequence.getJSONArray("steps").objects().forEachIndexed { index, step ->
                // A null url is an evaluation without a link (SDK: a foreground edge or
                // a re-enable while foregrounded; startup and a background re-enable
                // load the same set without sliding the expiry).
                val current = step.stringOrNull("url")?.let(UtmLinkParser::extract).orEmpty()
                val merged = UtmLinkParser.merge(stored, current)
                assertEquals("$name[$index]", step.stringOrNull("expected"), contextUtm(merged))
                // Web writes only a non-empty set; a merge never removes, so
                // an empty one can only follow an empty store anyway.
                if (merged.isNotEmpty()) stored = merged
            }
        }
    }

    /**
     * `envelope.context_canonical` is `JSON.stringify({ utm })`: the outer
     * escaping of the `utm` string inside `context`. Pinned both on the bare
     * renderer and on a real [EnvelopeBuilder] entry.
     */
    @Test
    fun envelopeVectorPinsTheOuterEscapingOfTheUtmString() {
        val envelope = vectors.getJSONObject("envelope")
        val utm = envelope.getString("utm")
        val canonical = envelope.getString("context_canonical")
        assertEquals(canonical, CanonicalJson.render(JSONObject().put("utm", utm)))

        val entry = EnvelopeBuilder.buildRaw(
            wireName = "cart.sync", dataJson = "{}", hash = "h", createdAtMillis = 0L, sentAtMillis = 0L,
            timezone = "-03:00", userId = null, anonymousId = "a", sessionId = "s", visitCount = 1,
            language = "pt-BR", screen = "1080x2400", appId = "77777", platform = "android", sdkVersion = "1.0.0",
            utm = utm,
        )
        val renderedContext = CanonicalJson.render(entry.getJSONObject("context"))
        assertTrue(renderedContext, renderedContext.contains(canonical.removePrefix("{").removeSuffix("}")))
    }

    // --- Merge and render (the pieces the vectors exercise end to end) ---

    @Test
    fun mergeKeepsStoredOrderUpdatesInPlaceAndAppendsNewKeysNeverRemoving() {
        val stored = listOf("utm_campaign" to "c", "utm_source" to "s")
        val current = listOf("utm_source" to "t", "utm_medium" to "m", "utm_journey" to "9")
        assertEquals(
            listOf("utm_campaign" to "c", "utm_source" to "t", "utm_medium" to "m", "utm_journey" to "9"),
            UtmLinkParser.merge(stored, current),
        )
        assertEquals(stored, UtmLinkParser.merge(stored, emptyList()))
        assertEquals(current, UtmLinkParser.merge(emptyList(), current))
    }

    /** `JSON.stringify` of a flat string map: pair order, compact, minimal escaping, lowercase hex. */
    @Test
    fun renderIsJsonStringifyOfTheOrderedPairs() {
        assertEquals("""{"utm_medium":"b","utm_source":"a"}""", UtmLinkParser.render(listOf("utm_medium" to "b", "utm_source" to "a")))
        // Escaped: `"` `\` \b \t \n \f \r, other C0 as lowercase \u00xx, lone
        // surrogates as lowercase \uXXXX. Raw: `/`, DEL, U+2028/2029,
        // non-ASCII and paired surrogates.
        assertEquals(
            "{\"utm_source\":\"\\\"\\\\\\b\\t\\n\\f\\r\\u0001\\u001f/\u007f\u2028\u2029ç😀\\ud800x\\udc00\"}",
            UtmLinkParser.render(listOf("utm_source" to "\"\\\b\t\n\u000c\r\u0001\u001f/\u007f\u2028\u2029ç😀\ud800x\udc00")),
        )
        assertEquals("{}", UtmLinkParser.render(emptyList()))
    }

    // --- Decoder: ECMA-262 decodeURIComponent, raw on any failure ---

    @Test
    fun decoderFollowsDecodeUriComponentAndKeepsTheRawValueOnFailure() {
        val cases = listOf(
            "a+b%20c" to "a+b c",                 // '+' is not a space
            "%26%3D%23%25%2F" to "&=#%/",         // every escape decodes, reserved included
            "promo%c3%a7%C3%A3o" to "promoção",   // hex in either case
            "promoção" to "promoção",             // raw non-ASCII passes through
            "%F0%9F%98%80" to "😀",
            "%F4%8F%BF%BF" to "\udbff\udfff",     // U+10FFFF, the last scalar
            "%00" to "\u0000",
            "%C3" to "%C3",                       // truncated sequence
            "%C3a" to "%C3a",                     // continuation must be an escape
            "%C3%41" to "%C3%41",                 // bad continuation byte
            "%80" to "%80",                       // lone continuation byte
            "%A9" to "%A9",                       // lone A0–BF continuation (Foundation would give U+FFFD)
            "%BF" to "%BF",
            "%C0%AF" to "%C0%AF",                 // overlong 2-byte
            "%E0%80%80" to "%E0%80%80",           // overlong 3-byte
            "%F0%80%80%80" to "%F0%80%80%80",     // overlong 4-byte
            "%ED%A0%80" to "%ED%A0%80",           // encoded surrogate
            "%F4%90%80%80" to "%F4%90%80%80",     // above U+10FFFF
            "%F8%80%80%80%80" to "%F8%80%80%80%80", // 5-byte lead
            "100%" to "100%",
            "%4" to "%4",
            "%zz" to "%zz",
            "ok%20then%C3" to "ok%20then%C3",     // one failure keeps the whole value raw
            "" to "",
        )
        for ((raw, expected) in cases) {
            assertEquals(raw, expected, UtmLinkParser.decodeURIComponentOrRaw(raw))
        }
    }

    /**
     * Differential fuzz against a JVM oracle: `decodeURIComponent` succeeds
     * iff every `%` starts a `%XX` escape and every maximal run of escapes is
     * well-formed UTF-8 (strict — no overlongs, surrogates or > U+10FFFF),
     * which is exactly what a `REPORT`-mode UTF-8 `CharsetDecoder` checks.
     * The production decoder is hand-rolled so JVM and ART agree; the
     * oracle only runs here.
     */
    @Test
    fun decoderAgreesWithAStrictUtf8OracleOnRandomEscapes() {
        val random = Random(20260923)
        val raws = listOf("a", "+", "ç", "😀", "\u0338", "%", "%Z", "%4", "|", "=")
        repeat(20_000) {
            val value = buildString {
                repeat(random.nextInt(0, 8)) {
                    if (random.nextInt(3) == 0) {
                        append(raws[random.nextInt(raws.size)])
                    } else {
                        // Bias toward UTF-8 structure: ASCII, continuation, lead bytes.
                        val byte = when (random.nextInt(4)) {
                            0 -> random.nextInt(0x00, 0x80)
                            1 -> random.nextInt(0x80, 0xC0)
                            2 -> random.nextInt(0xC0, 0xF8)
                            else -> random.nextInt(0x00, 0x100)
                        }
                        val hex = "%02X".format(byte)
                        append('%').append(if (random.nextBoolean()) hex else hex.lowercase())
                    }
                }
            }
            assertEquals(value, oracleDecode(value), UtmLinkParser.decodeURIComponentOrRaw(value))
        }
    }

    private fun oracleDecode(value: String): String {
        val out = StringBuilder()
        var i = 0
        while (i < value.length) {
            if (value[i] != '%') {
                out.append(value[i])
                i++
                continue
            }
            val bytes = ByteArrayOutputStream()
            while (i < value.length && value[i] == '%') {
                if (i + 2 >= value.length) return value
                val hex = value.substring(i + 1, i + 3)
                if (!hex.all { it in "0123456789abcdefABCDEF" }) return value
                bytes.write(hex.toInt(16))
                i += 3
            }
            val decoder = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            try {
                out.append(decoder.decode(ByteBuffer.wrap(bytes.toByteArray())))
            } catch (_: CharacterCodingException) {
                return value
            }
        }
        return out.toString()
    }

    // --- Hostile links (SPEC §3 never-throw; SPEC §11.1 allowlist) ---

    /**
     * Seeded fuzz over the characters the web rules key on (`?` `#` `/` `&`
     * `=` `%` `|` `+`), hex, non-ASCII, combining marks and lone surrogates
     * — half free-form token soup, half `key=value` queries built from the
     * allowlist with hostile separators and values: extraction never throws
     * and only ever yields allowlisted, non-empty, distinct keys in allowlist
     * order — never `utm_flow_params` itself — and the rendered JSON parses
     * back to exactly those pairs.
     */
    @Test
    fun hostileLinksNeverThrowAndYieldOnlyAllowlistedNonEmptyKeys() {
        val random = Random(20260924)
        val hostile = listOf(
            "?", "#", "/", "/#", "&", "=", "%", "|", "+", "%7C", "%7c", "%C3%A7", "%E0%A4%A", "%ED%A0%80",
            "%F0%9F%98%80", "%zz", "%2", "0", "9", "a", "F", "ç", "😀", "\u0338", "\u0301", "\ud800", "\udc00",
        )
        val keys = UtmLinkParser.ALLOWLIST + listOf("utm_flow_params", "utm_term", "UTM_SOURCE", "utm%5Fsource", "")
        val separators = listOf("&", "&", "&", "&", "?", "#", "/#", "=", "|", ";")
        fun soup(count: Int) = buildString { repeat(random.nextInt(0, count)) { append(hostile.random(random)) } }
        var captured = 0
        repeat(5_000) {
            val url = if (random.nextBoolean()) {
                soup(30) + keys.random(random) + soup(10)
            } else {
                buildString {
                    append(listOf("https://store.com/", "https://store.com/#/cart", "myapp://x", "").random(random))
                    append('?')
                    repeat(random.nextInt(1, 7)) { index ->
                        if (index > 0) append(separators.random(random))
                        append(keys.random(random))
                        append(listOf("=", "=", "=", "", "==").random(random))
                        append(soup(6))
                    }
                }
            }
            val pairs = UtmLinkParser.extract(url)
            if (pairs.isNotEmpty()) captured++
            val pairKeys = pairs.map { it.first }
            assertTrue(url, UtmLinkParser.ALLOWLIST.containsAll(pairKeys))
            assertFalse(url, "utm_flow_params" in pairKeys)
            assertEquals(url, pairKeys.distinct(), pairKeys)
            assertEquals(url, UtmLinkParser.ALLOWLIST.filter { it in pairKeys }, pairKeys)
            assertTrue(url, pairs.all { it.second.isNotEmpty() })

            val rendered = UtmLinkParser.render(UtmLinkParser.merge(emptyList(), pairs))
            val parsed = if (pairs.isEmpty()) JSONObject() else JSONObject(rendered)
            for ((key, value) in pairs) assertEquals(url, value, parsed.getString(key))
        }
        // Guard against a vacuous fuzz: the inputs must actually reach the allowlist.
        assertTrue("only $captured fuzzed links captured anything", captured > 1_000)
    }

    @Test
    fun degenerateLinksYieldNothing() {
        for (url in listOf("", "?", "??", "https://store.com/?#utm_source=a", "https://store.com/?/#utm_source=a", "https://store.com/?&=&")) {
            assertEquals(url, emptyList<Pair<String, String>>(), UtmLinkParser.extract(url))
        }
        // …but a query after a bare '#' is still the query (web reads the
        // text after the first '?', fragment or not).
        assertEquals(listOf("utm_source" to "undefined"), UtmLinkParser.extract("#?utm_source"))
    }
}
