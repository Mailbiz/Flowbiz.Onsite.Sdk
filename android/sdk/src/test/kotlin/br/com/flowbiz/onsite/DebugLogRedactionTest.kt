package br.com.flowbiz.onsite

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

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
     * SPEC §11.1/§12: UTM capture logs counts and reasons only — never the
     * link (its `_mb_cr_` carries the user id), a `key=value`, a value or
     * the `context.utm` JSON — across every evaluation path: capture, push
     * open, foreground, disabled capture, re-enable, a link without UTMs,
     * corrupt and expired stored state, and the disabled expired-set purge.
     */
    @Test
    fun utmCaptureLogsNeverContainTheLinkOrItsValues() {
        val hash = "eyJ0IjoiNzc3NzciLCJ1IjoicGlpLXVzZXItOTkifQ"
        val link = "https://store.com/carrinho?_mb_cr_=$hash&utm_source=probe-source" +
            "&utm_campaign=probe%20campaign&utm_flow_params=probe-step|probe-version|probe-instance"
        val captured = mutableListOf<String>()
        SdkLog.sink = { captured += it }
        try {
            val harness = CoreHarness(temp.newFolder())
            val push = Flowbiz.handlePush(
                mapOf("flowbiz" to JSONObject().put("v", 1).put("type", "cart_recovery").put("deep_link", link).toString())
            )
            harness.core.captureUtm(link)
            Flowbiz.handlePushOpened(push, harness.core)
            harness.core.onForeground()
            harness.core.track(Event.PageView("/carrinho"))
            harness.core.setEnabled(false)
            harness.core.captureUtm(link) // disabled-skip log path
            harness.core.setEnabled(true) // re-enable evaluation
            harness.store.values[StorageKeys.UTM_DATA] = "[[\"utm_source\",\"probe-corrupt\"]" // corrupt
            harness.core.onBackground()
            harness.core.onForeground()
            harness.core.captureUtm("https://store.com/produto/1?utm_source=") // nothing stored, nothing captured
            harness.core.captureUtm(link)
            harness.clock.advance(UtmStore.TTL_MS) // expired
            harness.core.onBackground()
            harness.core.onForeground()
            harness.core.captureUtm(link)
            harness.core.setEnabled(false)
            harness.clock.advance(UtmStore.TTL_MS) // expired while disabled
            harness.core.onBackground()
            harness.core.onForeground() // disabled purge path
            Flowbiz.handlePushOpened(push, harness.core) // disabled push-open path

            // Every UTM log path above actually fired — the enabled read and
            // the disabled purge each removed an expired set…
            for (path in listOf("utm context set", "utm capture skipped", "utm capture: no campaign", "discarded: corrupt", "discarded: expired")) {
                assertTrue("missing log path '$path' in: $captured", captured.any { it.contains(path) })
            }
            assertEquals(captured.toString(), 2, captured.count { it.contains("discarded: expired") })
            // …and none of them carries the link, a value or the JSON.
            val probes = listOf(
                link, hash, "store.com", "probe-source", "probe campaign", "probe%20campaign", "probe-step",
                "probe-version", "probe-instance", "probe-corrupt", "utm_source", "utm_campaign", "{", "=",
            )
            for (probe in probes) {
                assertFalse(
                    "debug log leaked '$probe' in: ${captured.filter { it.contains(probe) }}",
                    captured.any { it.contains(probe) },
                )
            }
        } finally {
            SdkLog.sink = null
        }
    }
}
