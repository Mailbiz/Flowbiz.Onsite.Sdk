package br.com.flowbiz.onsite

/**
 * Smoke coverage for the static [Flowbiz] facade WITHOUT Robolectric: only
 * the pre-initialize paths are reachable on a plain JVM ([Flowbiz.initialize]
 * needs a real `Context`), plus the `handleLink` / `handlePushOpened` seams,
 * which take the core as an argument. SPEC §3: every pre-init call must be a
 * silent no-op, never a throw.
 *
 * What is deliberately **not** covered here and rides on the demo app
 * (SPEC §14) instead: `initialize` production wiring (SharedPreferences,
 * queue file location, HttpUrlSender, ActivityLifecycleCallbacks
 * registration, `Log.d` sink) and double-initialize on a real Context. The
 * behavioral equivalents (first-config-wins config handling, lifecycle
 * edges, never-throw pipeline) are all pinned at the [FlowbizCore] level.
 */
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test

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

    /**
     * SPEC §3 platform-defensive nullability: the facade's reference
     * parameters are nullable so Java callers passing null get a logged
     * no-op, never an NPE (the bytecode-level proof — no
     * `Intrinsics.checkNotNullParameter` preamble — is
     * `FlowbizJavaNullSafetyTest`, compiled from Java source).
     */
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

    /**
     * SPEC §3: `handlePush` is pure and `handleLink` / `handlePushOpened`
     * decode purely — all *work* before initialize (no warning, real
     * result), unlike the pipeline entry points above; their UTM capture
     * (SPEC §11.1) needs initialize and stays silent before it. `handleLink`
     * with a real `Uri` needs Android (demo app), so a link is driven
     * through its String seam with no core — the pre-initialize state;
     * `handlePushOpened` is called through its public entry (no core is
     * installed here) and its seam. The string-level decoding is
     * `RecoveryLinkParserTest`, the initialized capture rules (and the
     * public entry with a core installed) `FlowbizCoreUtmTest`.
     */
    @Test
    fun pureHandlersWorkBeforeInitialize() {
        val warnings = mutableListOf<String>()
        SdkLog.sink = { warnings += it }
        try {
            val push = Flowbiz.handlePush(mapOf("flowbiz" to """{"v":1,"type":"promo","title":"t"}"""))
            assertTrue(push != null && push.type == "promo")
            assertTrue(Flowbiz.handlePush(mapOf("other" to "x")) == null)
            assertTrue(Flowbiz.handleLink(null) == null)
            // A recovery link carrying UTMs: decoded (no tenant check before
            // initialize), nothing captured, and — like everything here — no log.
            val link = FixtureSupport.utmExtractVector("messagebuilder_journey_cart_recovery").getString("url")
            assertTrue(Flowbiz.handleLink(link, current = null)?.cartId == "cart-abc-001")
            // The same link as an opened push's deep_link: decoded the same way.
            val opened = Flowbiz.handlePush(
                mapOf("flowbiz" to JSONObject().put("v", 1).put("type", "cart_recovery").put("deep_link", link).toString())
            )
            assertTrue(Flowbiz.handlePushOpened(opened)?.cartId == "cart-abc-001")
            assertTrue(Flowbiz.handlePushOpened(opened, current = null)?.cartId == "cart-abc-001")
            assertTrue(Flowbiz.handlePushOpened(push) == null) // no deep_link
            assertTrue(Flowbiz.handlePushOpened(null) == null)
            assertTrue(warnings.isEmpty()) // pure: no "initialize was not called" warnings
        } finally {
            SdkLog.sink = null
        }
    }
}
