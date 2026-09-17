package br.com.flowbiz.onsite

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
}
