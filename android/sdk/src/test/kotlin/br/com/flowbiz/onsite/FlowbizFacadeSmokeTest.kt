package br.com.flowbiz.onsite

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Without Robolectric only the pre-initialize paths are reachable:
 * [Flowbiz.initialize] needs a real `Context`. Its production wiring runs in
 * the demo app; the behavior behind it is pinned on [FlowbizCore].
 */
class FlowbizFacadeSmokeTest {

    @Test
    fun preInitializeCallsAreSilentNoOpsAndNeverThrow() {
        val warnings = mutableListOf<String>()
        SdkLog.sink = { warnings += it }
        try {
            Flowbiz.track(Event.PageView("home"))
            Flowbiz.track(
                Event.ProductView(
                    Product(productId = "P1", variants = listOf(ProductVariant(sku = "S1", price = Double.NaN)))
                )
            )
            Flowbiz.logout()
            Flowbiz.setEnabled(false)
            Flowbiz.setEnabled(true)
            Flowbiz.flush()
            Flowbiz.setPushToken("fcm-token-1")
            Flowbiz.removePushToken()
            assertTrue(warnings.all { it.contains("ignored") })
            assertTrue(warnings.size == 8) // each call logged a debug warning
        } finally {
            SdkLog.sink = null
        }
    }

    /** Java callers can pass null; `FlowbizJavaNullSafetyTest` proves it from Java source. */
    @Test
    fun nullArgumentsAreLoggedNoOpsAndNeverThrow() {
        val warnings = mutableListOf<String>()
        SdkLog.sink = { warnings += it }
        try {
            Flowbiz.track(null)
            Flowbiz.initialize(null, FlowbizConfig(appId = "77777", baseUri = "https://store.com"))
            Flowbiz.initialize(null, null)
            Flowbiz.setPushToken(null)
            Flowbiz.setPushToken("   ")
            assertTrue(warnings.size == 5)
            assertTrue(warnings.all { it.contains("ignored") })
        } finally {
            SdkLog.sink = null
        }
    }

    /** A real `Uri` needs Android; `RecoveryLinkParserTest` covers `handleLink` on strings. */
    @Test
    fun pureHandlersWorkBeforeInitialize() {
        val warnings = mutableListOf<String>()
        SdkLog.sink = { warnings += it }
        try {
            val push = Flowbiz.handlePush(mapOf("flowbiz" to """{"v":1,"type":"promo","title":"t"}"""))
            assertTrue(push != null && push.type == "promo")
            assertTrue(Flowbiz.handlePush(mapOf("other" to "x")) == null)
            assertTrue(Flowbiz.handleLink(null) == null)
            assertTrue(warnings.isEmpty())
        } finally {
            SdkLog.sink = null
        }
    }
}
