package com.flowbiz.onsite

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
