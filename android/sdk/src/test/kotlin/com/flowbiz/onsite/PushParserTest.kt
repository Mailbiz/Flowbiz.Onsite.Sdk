package com.flowbiz.onsite

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File
import kotlin.random.Random

/**
 * `handlePush` (SPEC §10.2/§10.3) driven by the shared drift-guard samples
 * (`shared/push-samples/samples.json`). Samples are exercised through the
 * public facade — `handlePush` is pure and requires no initialize (SPEC §3).
 */
class PushParserTest {

    private fun samples(): JSONArray =
        JSONArray(File(FixtureSupport.sharedDir("push-samples"), "samples.json").readText())

    /**
     * Builds the FCM-shaped `Map<String, String>` for a sample. A non-string
     * marker value (the `non_string_marker_dict` sample) is smuggled in via
     * an erasure-level cast — exactly what a hostile/buggy Java caller could
     * do; the SDK must degrade to null, never throw.
     */
    private fun payloadMap(payload: JSONObject): Map<String, String> {
        val map = HashMap<String, Any>()
        val keys = payload.keys()
        while (keys.hasNext()) {
            val key = keys.next() as String
            when (val value = payload.get(key)) {
                is String -> map[key] = value
                else -> map[key] = value // non-string smuggled through erasure
            }
        }
        @Suppress("UNCHECKED_CAST")
        return map as Map<String, String>
    }

    @Test
    fun allSharedSamplesParseAsExpected() {
        val samples = samples()
        for (i in 0 until samples.length()) {
            val sample = samples.getJSONObject(i)
            val name = sample.getString("name")
            val expected = when {
                sample.has("expected_android") -> sample.opt("expected_android")
                else -> sample.opt("expected")
            }
            val push = Flowbiz.handlePush(payloadMap(sample.getJSONObject("payload")))
            if (expected == null || expected == JSONObject.NULL) {
                assertNull("sample '$name' must be null", push)
            } else {
                assertNotNull("sample '$name' must parse", push)
                assertPushMatches(name, expected as JSONObject, push!!)
            }
            if (sample.has("expected_recovery")) {
                assertRecoveryMatches(name, sample.getJSONObject("expected_recovery"), push!!.recoveryPayload)
            }
        }
    }

    private fun assertPushMatches(name: String, expected: JSONObject, push: FlowbizPush) {
        assertEquals("$name: version", expected.getInt("version"), push.version)
        assertEquals("$name: type", expected.getString("type"), push.type)
        assertEquals("$name: title", expected.optStringOrNull("title"), push.title)
        assertEquals("$name: body", expected.optStringOrNull("body"), push.body)
        assertEquals("$name: deepLink", expected.optStringOrNull("deepLink"), push.deepLinkString)
        val dataDiff = FixtureSupport.diff(expected.getJSONObject("data"), JSONObject(push.data), "$name.data")
        assertNull(dataDiff, dataDiff)
    }

    private fun assertRecoveryMatches(name: String, expected: JSONObject, recovery: RecoveryPayload?) {
        assertNotNull("$name: recoveryPayload", recovery)
        assertEquals("$name: cartId", expected.getString("cartId"), recovery!!.cartId)
        assertEquals("$name: userId", expected.getString("userId"), recovery.userId)
        val products = expected.getJSONArray("products")
        assertEquals("$name: product count", products.length(), recovery.products.size)
        for (i in 0 until products.length()) {
            val expectedProduct = products.getJSONObject(i)
            val product = recovery.products[i]
            assertEquals(expectedProduct.getString("productId"), product.productId)
            assertEquals(expectedProduct.getString("sku"), product.sku)
            assertEquals(expectedProduct.getInt("quantity"), product.quantity)
            if (expectedProduct.isNull("recoveryProperties")) {
                assertNull(product.recoveryProperties)
            } else {
                val diff = FixtureSupport.diff(
                    expectedProduct.getJSONObject("recoveryProperties"),
                    JSONObject(product.recoveryProperties!!),
                    "$name.products[$i].recoveryProperties",
                )
                assertNull(diff, diff)
            }
        }
    }

    private fun JSONObject.optStringOrNull(key: String): String? =
        if (has(key) && !isNull(key)) getString(key) else null

    // MARK: purity / never-throw

    /** SPEC §3: handlePush and handleLink are pure — no initialize needed (see also FlowbizFacadeSmokeTest). */
    @Test
    fun handlePushWorksWithoutInitialize() {
        val push = Flowbiz.handlePush(mapOf("flowbiz" to """{"v":1,"type":"promo"}"""))
        assertNotNull(push)
        assertEquals("promo", push!!.type)
    }

    @Test
    fun nullAndEmptyPayloadsAreNull() {
        assertNull(Flowbiz.handlePush(null))
        assertNull(Flowbiz.handlePush(emptyMap()))
    }

    @Test
    fun randomGarbageMarkerNeverThrows() {
        val random = Random(7)
        repeat(300) {
            val garbage = buildString {
                repeat(random.nextInt(0, 80)) { append(random.nextInt(0x20, 0x2FFF).toChar()) }
            }
            Flowbiz.handlePush(mapOf("flowbiz" to garbage)) // must not throw
        }
    }
}
