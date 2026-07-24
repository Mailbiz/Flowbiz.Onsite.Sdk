package com.flowbiz.onsite

import org.json.JSONException
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drift-guard tests: every fixture in `shared/fixtures/` is mapped onto the
 * typed constructors, serialized, and the produced `data` JSON string is
 * structurally compared against `expected.data`. The Swift test suite runs
 * the exact same fixtures — if the two SDKs disagree, the code is wrong,
 * never the fixture.
 */
class WireFixtureTest {

    @Test
    fun allFixturesProduceExpectedWirePayload() {
        val files = FixtureSupport.fixtureFiles()
        assertTrue("no fixtures found", files.isNotEmpty())

        val failures = mutableListOf<String>()
        for (file in files) {
            try {
                val fixture = JSONObject(file.readText())
                val event = FixtureSupport.buildEvent(
                    fixture.getString("event"),
                    fixture.optJSONObject("input") ?: JSONObject(),
                )
                val expected = fixture.getJSONObject("expected")

                val wireName = EventSerializer.wireName(event)
                if (wireName != expected.getString("wire_event")) {
                    failures += "${file.name}: wire_event expected '${expected.getString("wire_event")}' but was '$wireName'"
                }

                // Serialize to the wire string, then parse it back — the wire
                // string is what actually ships.
                val wireString = EventSerializer.dataJson(event)
                FixtureSupport.diff(expected.getJSONObject("data"), JSONObject(wireString), "data")?.let {
                    failures += "${file.name}: $it"
                }

                // Byte-for-byte pin of the canonical wire string (sorted
                // keys, JSON.stringify-compatible numbers and escaping) —
                // any future number/escaping divergence fails here.
                val canonical = expected.getString("data_canonical")
                if (wireString != canonical) {
                    failures += "${file.name}: canonical wire string mismatch\n" +
                        "  expected: $canonical\n" +
                        "  produced: $wireString"
                }
            } catch (e: Exception) {
                failures += "${file.name}: threw $e"
            }
        }
        assertTrue("fixture mismatches:\n" + failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun fixturesCoverAllTwelveEventTypes() {
        val covered = FixtureSupport.fixtureFiles()
            .map { JSONObject(it.readText()).getString("event") }
            .toSet()
        val all = setOf(
            "pageView", "accountLogin", "accountSync", "productView",
            "cartSync", "addToCart", "cartItemUpdate", "cartSetPostalCode",
            "cartSetCoupon", "checkoutStep", "orderComplete", "orderCancel",
        )
        assertEquals(all, covered)
    }

    @Test
    fun fixtureNameMatchesFileName() {
        for (file in FixtureSupport.fixtureFiles()) {
            val fixture = JSONObject(file.readText())
            assertEquals(file.nameWithoutExtension, fixture.getString("name"))
        }
    }

    /**
     * Garbage-input contract, aligned with Swift: serialization throws on
     * non-finite numbers (SPEC §3's never-throw boundary lands in Slice 4).
     */
    @Test
    fun nonFiniteNumbersThrow() {
        for (garbage in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            val event = Event.CartSync(
                Cart(cartId = "c-1", subtotal = garbage, total = 0.0, freight = 0.0, tax = 0.0, discounts = 0.0)
            )
            assertThrows(JSONException::class.java) { EventSerializer.dataJson(event) }
        }
    }
}
