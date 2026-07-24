package com.flowbiz.onsite

/**
 * Smoke coverage for the static [Flowbiz] facade WITHOUT Robolectric: only
 * the pre-initialize paths are reachable on a plain JVM ([Flowbiz.initialize]
 * needs a real `Context`). SPEC §3: every pre-init call must be a silent
 * no-op, never a throw.
 *
 * What is deliberately **not** covered here and rides on the demo app
 * (SPEC §14) instead: `initialize` production wiring (SharedPreferences,
 * queue file location, HttpUrlSender, ActivityLifecycleCallbacks
 * registration, `Log.d` sink) and double-initialize on a real Context. The
 * behavioral equivalents (first-config-wins config handling, lifecycle
 * edges, never-throw pipeline) are all pinned at the [FlowbizCore] level.
 */
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
            assertTrue(warnings.all { it.contains("ignored") })
            assertTrue(warnings.size == 6) // each call logged a debug warning
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
            Flowbiz.initialize(null, FlowbizConfig(appId = "77777"))
            Flowbiz.initialize(null, null)
            assertTrue(warnings.size == 3)
            assertTrue(warnings.all { it.contains("ignored") && it.contains("null") })
        } finally {
            SdkLog.sink = null
        }
    }
}
