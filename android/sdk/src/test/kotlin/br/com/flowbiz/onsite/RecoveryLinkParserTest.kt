package br.com.flowbiz.onsite

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Base64

/**
 * `handleLink` decoding (SPEC §11): the `_mb_cr_` + `utm_source` link the
 * backend emits, pinned by `shared/recovery-links/vectors.json`.
 */
class RecoveryLinkParserTest {

    private val vectors: List<JSONObject> by lazy {
        val array = JSONArray(File(FixtureSupport.sharedDir("recovery-links"), "vectors.json").readText())
        (0 until array.length()).map { array.getJSONObject(it) }
    }

    @Test
    fun allSharedVectorsDecodeAsExpected() {
        assertTrue(vectors.size >= 20)
        for (vector in vectors) {
            val name = vector.getString("name")
            val appId = if (vector.isNull("appId")) null else vector.getString("appId")
            val actual = RecoveryLinkParser.parse(vector.getString("url"), appId)
            if (vector.isNull("expected")) {
                assertNull("$name: expected null", actual)
            } else {
                assertNotNull("$name: expected a payload", actual)
                assertEquals(name, payload(vector.getJSONObject("expected")), actual)
            }
        }
    }

    @Test
    fun plusTurnedIntoSpaceStillDecodes() {
        val json = """{"t":"77777","u":"u","c":"c","its":[["1","P>>1","S"]]}"""   // '>' forces a '+' in base64
        val b64 = Base64.getEncoder().encodeToString(json.toByteArray())
        assertTrue(b64.contains("+"))
        val link = "https://store.com/c?utm_source=flowbiz&_mb_cr_=" + b64.replace('+', ' ')
        assertEquals("P>>1", RecoveryLinkParser.parse(link)!!.products.first().productId)
    }

    @Test
    fun nullAndGarbageNeverThrow() {
        assertNull(RecoveryLinkParser.parse(null))
        assertNull(RecoveryLinkParser.parse(""))
        assertNull(RecoveryLinkParser.parse("?&&=&_mb_cr_&utm_source"))
    }

    /**
     * I3: seeded fuzz over the *decoded* hash JSON (not just URL bytes) —
     * `its` and item slots take every adversarial shape SPEC §3 must
     * survive (wrong types, huge/negative numbers, deep nesting, giant
     * strings). The only assertion is that `parse` returns (null or a
     * payload) instead of throwing.
     */
    @Test
    fun adversarialDecodedHashesNeverThrow() {
        val generator = SplitMix64(20260902L)
        repeat(300) {
            val hash = randomHash(generator)
            val b64 = Base64.getEncoder().encodeToString(hash.toString().toByteArray())
            val url = "https://store.com/c?utm_source=flowbiz&_mb_cr_=$b64"
            RecoveryLinkParser.parse(url, "77777") // must not throw
        }
    }

    /** One adversarial `{t, u, c, its}` hash — see [randomField]/[randomIts]. */
    private fun randomHash(gen: SplitMix64): JSONObject =
        JSONObject()
            .put("t", randomField(gen))
            .put("u", randomField(gen))
            .put("c", randomField(gen))
            .put("its", randomIts(gen))

    private fun randomField(gen: SplitMix64): Any = when ((gen.next() % 5UL).toInt()) {
        0 -> "field-${gen.next() % 1000UL}"
        1 -> (gen.next() % 100_000UL).toInt()
        2 -> (gen.next() % 2UL) == 0UL
        3 -> JSONObject.NULL
        else -> ""
    }

    /** `its`: usually an array of items, occasionally a non-array. */
    private fun randomIts(gen: SplitMix64): Any = when ((gen.next() % 6UL).toInt()) {
        0 -> JSONObject.NULL
        1 -> "not an array"
        2 -> (gen.next() % 1000UL).toInt()
        3 -> JSONObject().put("k", "v")
        4 -> JSONArray()
        else -> {
            val items = JSONArray()
            val count = (gen.next() % 4UL).toInt() + 1
            repeat(count) { items.put(randomItem(gen)) }
            items
        }
    }

    /** One `its` element: usually an array of adversarial slots, sometimes a non-array item. */
    private fun randomItem(gen: SplitMix64): Any {
        if ((gen.next() % 4UL) == 0UL) return randomSlot(gen)
        val item = JSONArray()
        val slotCount = (gen.next() % 5UL).toInt()
        repeat(slotCount) { item.put(randomSlot(gen)) }
        return item
    }

    /**
     * One `its[i]` slot value: a huge/negative/out-of-Int32-range number, a
     * bool, null, a nested object, a deeply nested array (depth 20), an
     * empty string, or a ~10 kB string.
     */
    private fun randomSlot(gen: SplitMix64): Any = when ((gen.next() % 9UL).toInt()) {
        0 -> 1e30
        1 -> -1e30
        2 -> 1e308
        3 -> (gen.next() % 2UL) == 0UL
        4 -> JSONObject.NULL
        5 -> JSONObject().put("nested", "object")
        6 -> {
            var value: Any = JSONArray().put("leaf")
            repeat(20) { value = JSONArray().put(value) }
            value
        }
        7 -> ""
        else -> "x".repeat(10_000)
    }

    private fun payload(json: JSONObject): RecoveryPayload {
        val products = json.getJSONArray("products").let { arr ->
            (0 until arr.length()).map { i ->
                val item = arr.getJSONObject(i)
                RecoveryProduct(
                    productId = item.getString("productId"),
                    sku = item.getString("sku"),
                    quantity = item.getInt("quantity"),
                    recoveryProperties = if (item.isNull("recoveryProperties")) null
                        else JsonPlain.toPlainMap(item.getJSONObject("recoveryProperties")),
                )
            }
        }
        return RecoveryPayload(json.getString("cartId"), json.getString("userId"), products)
    }
}

/** Tiny deterministic PRNG mirroring iOS's `SplitMix64` (`PushParserSuite.swift`). */
private class SplitMix64(seed: Long) {
    private var state = seed.toULong()

    fun next(): ULong {
        state += 0x9E3779B97F4A7C15UL
        var z = state
        z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9UL
        z = (z xor (z shr 27)) * 0x94D049BB133111EBUL
        return z xor (z shr 31)
    }
}
