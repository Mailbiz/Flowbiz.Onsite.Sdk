package br.com.flowbiz.onsite

import org.json.JSONException
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class WireFixtureTest {

    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun allFixturesProduceExpectedWirePayload() {
        val files = FixtureSupport.fixtureFiles()
        assertTrue("no fixtures found", files.isNotEmpty())

        val failures = mutableListOf<String>()
        for (file in files) {
            try {
                val fixture = JSONObject(file.readText())
                val built = FixtureSupport.buildEvent(
                    fixture.getString("event"),
                    fixture.optJSONObject("input") ?: JSONObject(),
                )
                val expected = fixture.getJSONObject("expected")
                val event = UserSanitizer.sanitize(built)
                val dropped = expected.optBoolean("dropped")
                if (event == null || dropped) {
                    if ((event == null) != dropped) failures += "${file.name}: expected dropped=$dropped"
                    continue
                }
                val baseUri = if (fixture.has("baseUri")) fixture.getString("baseUri") else null

                val wireName = EventSerializer.wireName(event)
                if (wireName != expected.getString("wire_event")) {
                    failures += "${file.name}: wire_event expected '${expected.getString("wire_event")}' but was '$wireName'"
                }

                val wireString = EventSerializer.dataJson(event, baseUri)
                FixtureSupport.diff(expected.getJSONObject("data"), JSONObject(wireString), "data")?.let {
                    failures += "${file.name}: $it"
                }

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
    fun accountFixturesPinTheIdentityOfTheEnvelope() {
        val accounts = FixtureSupport.fixtureFiles().map { JSONObject(it.readText()) }
            .filter { it.getString("event").startsWith("account") }
        assertTrue(accounts.size >= 10)
        for (fixture in accounts) {
            val name = fixture.getString("name")
            val expected = fixture.getJSONObject("expected")
            val h = CoreHarness(temp.newFolder())
            h.core.track(FixtureSupport.buildEvent(fixture.getString("event"), fixture.getJSONObject("input")))
            if (expected.optBoolean("dropped")) {
                assertTrue(name, h.sender.bodies.isEmpty())
                assertEquals(name, null, h.store.getString(StorageKeys.USER_ID))
                continue
            }
            val entry = h.lastEntry()
            assertEquals(name, expected.getString("data_canonical"), entry.getString("data"))
            assertEquals(name, expected.getString("identity_user_id"), entry.getJSONObject("identity").getString("user_id"))
            assertEquals(name, expected.getString("identity_user_id"), h.store.getString(StorageKeys.USER_ID))
            val email = expected.getJSONObject("data").getJSONObject("user").opt("email")
            assertEquals(name, email, h.store.getString(StorageKeys.EMAIL))
        }
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
