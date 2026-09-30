package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import kotlin.random.Random

class UtmLinkParserTest {

    @Test
    fun everyExtractVectorRendersTheWebContextUtm() {
        val vectors = FixtureSupport.utmExtractVectors()
        assertTrue("truncated vectors.json", vectors.size >= 60)
        for ((name, vector) in vectors) {
            val utms = UtmLinkParser.extract(vector.url!!)
            assertEquals(name, vector.expected, utms.takeIf { it.isNotEmpty() }?.let(CanonicalJson::renderStringPairs))
        }
    }

    @Test
    fun decoderMatchesAnOracleAndHostileLinksExtractOnlyAllowlistedUtms() {
        val random = Random(20260929)
        val raw = listOf(
            "a", "+", "ç", "😀", "̸", "\ud800", "%", "%Z", "%4", "%+1", "%-1", "%١٢", "%ＡＢ",
            "|", "=", "&", "?", "#", "/#",
        )
        val keys = UtmLinkParser.ALLOWLIST + "utm_flow_params"
        repeat(20_000) {
            val value = buildString {
                repeat(random.nextInt(0, 8)) {
                    if (random.nextInt(3) == 0) {
                        append(raw.random(random))
                    } else {
                        val byte = when (random.nextInt(4)) {
                            0 -> random.nextInt(0x00, 0x80)
                            1 -> random.nextInt(0x80, 0xC0)
                            2 -> random.nextInt(0xC0, 0xF8)
                            else -> random.nextInt(0x00, 0x100)
                        }
                        val hex = byte.toString(16).padStart(2, '0')
                        append('%').append(if (random.nextBoolean()) hex else hex.uppercase())
                    }
                }
            }
            assertEquals(value, oracle(value), UtmLinkParser.decodeURIComponentOrRaw(value))

            val utms = UtmLinkParser.extract("https://store.com/?${keys.random(random)}=$value&$value")
            assertTrue(value, utms.all { (key, v) -> key in UtmLinkParser.ALLOWLIST && v.isNotEmpty() })
        }
    }

    private fun oracle(value: String): String {
        val out = StringBuilder()
        var i = 0
        while (i < value.length) {
            if (value[i] != '%') {
                out.append(value[i++])
                continue
            }
            val bytes = ByteArrayOutputStream()
            while (i < value.length && value[i] == '%') {
                val hex = value.substring(i + 1, minOf(i + 3, value.length))
                if (hex.length < 2 || !hex.all { it in "0123456789abcdefABCDEF" }) return value
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
}
