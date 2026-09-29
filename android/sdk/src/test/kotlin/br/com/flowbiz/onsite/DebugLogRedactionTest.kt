package br.com.flowbiz.onsite

import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * SPEC §12: `debug` logging never prints PII. Pins the invariant end-to-end:
 * a full pipeline scenario (account login with email/phone/name, push token
 * relay, dedup suppression, disabled drops, a serialization failure) is run
 * with the debug sink captured, and none of the captured lines may contain
 * any of the PII values — logs carry wire event names, counts, codes and
 * exception class names only, never `data` payload strings or tokens.
 */
class DebugLogRedactionTest {

    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun trackedPiiNeverAppearsInCapturedDebugLogs() {
        val email = "pii-probe.email@example.com"
        val phone = "+5511987654321"
        val name = "Maria da Silva Probe"
        val token = "pii-secret-fcm-token-XYZ123"

        val captured = mutableListOf<String>()
        SdkLog.sink = { captured += it }
        try {
            val harness = CoreHarness(temp.newFolder())
            val user = User(userId = "u-77", email = email, phone = phone, name = name)
            harness.core.track(Event.AccountLogin(user))
            harness.core.track(Event.AccountLogin(user)) // dedup-suppression log path
            harness.core.setPushToken(token)
            harness.core.setPushToken(token) // dedup-suppression log path for the token event
            harness.core.track( // serialization-failure (dropped event) log path
                Event.ProductView(
                    Product(productId = "P1", variants = listOf(ProductVariant(sku = "S1", price = Double.NaN)))
                )
            )
            harness.core.setEnabled(false)
            harness.core.track(Event.AccountSync(user)) // disabled-drop log path
            harness.core.setEnabled(true) // re-enable + stored-token re-emit path
            harness.core.removePushToken()
            harness.core.setPushToken(token)
            harness.core.logout() // logout removal + summary log path
            harness.core.flush()

            assertTrue("scenario must produce debug logs", captured.isNotEmpty())
            for (pii in listOf(email, phone, name, token)) {
                assertFalse(
                    "debug log leaked PII '$pii' in: ${captured.filter { it.contains(pii) }}",
                    captured.any { it.contains(pii) },
                )
            }
        } finally {
            SdkLog.sink = null
        }
    }

    /**
     * UTM logs carry counts and reasons only, across capture, discard and a
     * failed refresh (which keeps the context).
     */
    @Test
    fun utmLogsNeverCarryALinkAKeyOrAValue() {
        val link = "https://store.com/?_mb_cr_=eyJ0IjoiNzc3NzciLCJ1IjoicGlpLXByb2JlIn0&utm_source=probe-source" +
            "&utm_campaign=probe%20campaign&utm_flow_params=probe-step|probe-version|probe-instance"
        val kv = FakeKeyValueStore()
        var failingReads = false
        val store = object : KeyValueStore by kv {
            override fun getString(key: String): String? =
                if (failingReads) throw IllegalStateException(link) else kv.getString(key)
        }
        val clock = FakeClock()
        val sender = FakeHttpSender()
        val captured = mutableListOf<String>()
        SdkLog.sink = { captured += it }
        try {
            val core = FlowbizCore(
                config = FlowbizConfig(appId = "77777", baseUri = "https://store.com"),
                store = store,
                queueFactory = { EventQueue(File(temp.newFolder(), "queue.jsonl")) },
                sender = sender,
                scheduler = FakeTaskScheduler(),
                clock = clock,
                deviceContext = FakeDeviceContext(),
                reachability = FakeReachability(),
            )
            Flowbiz.handleLink(link, core)
            failingReads = true
            Flowbiz.handleLink(link, core)
            failingReads = false
            core.track(Event.PageView("/carrinho"))
            kv.values[StorageKeys.UTM_DATA] = """[["utm_source","probe-corrupt"]"""
            core.onForeground()
            Flowbiz.handleLink(link, core)
            clock.advance(UtmStore.TTL_MS)
            core.onBackground()
            core.onForeground()
        } finally {
            SdkLog.sink = null
        }
        val afterFailure = JSONObject(sender.bodies.first()).getJSONArray("data").getJSONObject(0)
        assertTrue(afterFailure.getJSONObject("context").has("utm"))
        val paths = listOf(
            "utm context: 5 captured", "discarded: corrupt", "discarded: expired", "utm refresh failed: IllegalStateException",
        )
        for (path in paths) {
            assertTrue("no '$path' in $captured", captured.any { path in it })
        }
        for (probe in listOf("probe", "eyJ0", "store.com", "utm_", "{", "=")) {
            assertFalse("'$probe' leaked in $captured", captured.any { probe in it })
        }
    }
}
