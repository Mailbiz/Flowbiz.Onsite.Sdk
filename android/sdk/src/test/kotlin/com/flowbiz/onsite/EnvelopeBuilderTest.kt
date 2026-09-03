package com.flowbiz.onsite

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Envelope shape tests for the SPEC §4 entry produced by [EnvelopeBuilder]. */
class EnvelopeBuilderTest {

    // 2023-11-14T22:13:20 UTC
    private val createdAtMillis = 1_700_000_000_000L
    private val sentAtMillis = 1_700_000_000_123L

    private fun build(
        event: Event = Event.CartSync(
            Cart(cartId = "c-9f81b2e0", subtotal = 0.0, total = 0.0, freight = 0.0, tax = 0.0, discounts = 0.0)
        ),
        userId: String? = "98412",
    ): JSONObject = EnvelopeBuilder.build(
        event = event,
        hash = "7f9c31c2-6a5e-4e0f-9c1d-2b8a4d3e5f60",
        createdAtMillis = createdAtMillis,
        sentAtMillis = sentAtMillis,
        timezone = "-03:00",
        userId = userId,
        anonymousId = "a3b1c5d7-1111-4222-8333-444455556666",
        sessionId = "e9f8d7c6-7777-4888-9999-000011112222",
        visitCount = 3,
        language = "pt-BR",
        screen = "1080x2400",
        appId = "77777",
        platform = "android",
        sdkVersion = "1.0.0",
    )

    @Test
    fun allEnvelopeFieldsPresent() {
        val envelope = build()
        assertEquals("cart.sync", envelope.getString("event"))
        assertEquals("7f9c31c2-6a5e-4e0f-9c1d-2b8a4d3e5f60", envelope.getString("hash"))
        assertEquals("77777", envelope.getString("app_id"))
        assertEquals("android", envelope.getString("platform"))
        assertEquals("flowbiz-android-sdk", envelope.getString("v_tracker"))
        assertEquals("android-1.0.0", envelope.getString("v_version"))

        val identity = envelope.getJSONObject("identity")
        assertEquals("98412", identity.getString("user_id"))
        assertEquals("a3b1c5d7-1111-4222-8333-444455556666", identity.getString("anonymous_id"))
        assertEquals("e9f8d7c6-7777-4888-9999-000011112222", identity.getString("session_id"))
        assertEquals(3, identity.getInt("visit_count"))

        val context = envelope.getJSONObject("context")
        assertEquals("android", context.getString("platform"))
        assertEquals("pt-BR", context.getString("language"))
        assertEquals("1080x2400", context.getString("screen"))
        assertEquals("flowbiz-android-sdk", context.getString("vendor"))
        assertEquals("1.0.0", context.getString("onsite_version"))
    }

    @Test
    fun dataIsAJsonStringNotANestedObject() {
        val envelope = build()
        val data = envelope.get("data")
        assertTrue("data must be a String on the wire", data is String)
        // ... and it must parse back to the payload object.
        val parsed = JSONObject(data as String)
        assertEquals("c-9f81b2e0", parsed.getJSONObject("cart").getString("cart_id"))
    }

    @Test
    fun timingsAreIso8601MillisUtc() {
        val timings = build().getJSONObject("timings")
        assertEquals("2023-11-14T22:13:20.000Z", timings.getString("created_at"))
        assertEquals("2023-11-14T22:13:20.123Z", timings.getString("sent_at"))
        assertEquals("-03:00", timings.getString("timezone"))

        val isoMillis = Regex("""\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z""")
        assertTrue(isoMillis.matches(timings.getString("created_at")))
        assertTrue(isoMillis.matches(timings.getString("sent_at")))
    }

    @Test
    fun userIdOmittedWhenNull() {
        val identity = build(userId = null).getJSONObject("identity")
        assertFalse(identity.has("user_id"))
        assertTrue(identity.has("anonymous_id"))
    }

    private fun buildWithContext(
        event: Event = Event.CartSetCoupon(cartId = "c-1", coupon = "X"),
        contextUrl: String? = null,
        baseUri: String? = null,
        recoveryUrl: String? = null,
    ): JSONObject = EnvelopeBuilder.build(
        event = event, hash = "h", createdAtMillis = createdAtMillis, sentAtMillis = sentAtMillis,
        timezone = "-03:00", userId = null, anonymousId = "a", sessionId = "s", visitCount = 1,
        language = "pt-BR", screen = "1080x2400", appId = "77777", platform = "android", sdkVersion = "1.0.0",
        contextUrl = contextUrl, baseUri = baseUri, recoveryUrl = recoveryUrl,
    )

    @Test
    fun contextCarriesUrlBaseUriAndRecoveryUrlWhenGiven() {
        val context = buildWithContext(
            contextUrl = "https://store.com/checkout",
            baseUri = "https://store.com",
            recoveryUrl = "https://store.com/carrinho",
        ).getJSONObject("context")
        assertEquals("https://store.com/checkout", context.getString("url"))
        assertEquals("https://store.com", context.getString("baseuri"))
        assertEquals("https://store.com/carrinho", context.getString("recoveryUrl"))
        assertFalse(context.has("title"))
    }

    @Test
    fun contextOmitsUrlBaseUriAndRecoveryUrlByDefault() {
        val context = build(event = Event.PageView("/checkout")).getJSONObject("context")
        assertFalse(context.has("url"))
        assertFalse(context.has("baseuri"))
        assertFalse(context.has("recoveryUrl"))
    }

    @Test
    fun emptyBaseUriIsOmitted() {
        assertFalse(buildWithContext(baseUri = "").getJSONObject("context").has("baseuri"))
    }

    @Test
    fun buildUsesBaseUriToResolveDataUrls() {
        val envelope = buildWithContext(event = Event.PageView(path = "/checkout", title = "Checkout"), baseUri = "https://store.com")
        assertEquals("""{"page":{"title":"Checkout","url":"https://store.com/checkout"}}""", envelope.getString("data"))
    }
}
