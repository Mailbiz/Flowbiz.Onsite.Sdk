package com.flowbiz.onsite.demo

import android.app.Application
import com.flowbiz.onsite.Flowbiz
import com.flowbiz.onsite.FlowbizConfig

/**
 * Fake-store demo application (SPEC §14): exercises every public SDK API
 * against the production wiring (SharedPreferences, JSONL queue file,
 * lifecycle callbacks, real clock/network).
 *
 * The collectorUrl is left at its default. Offline (or with the placeholder
 * appId rejected upstream) the POSTs fail harmlessly — which is the point:
 * it demonstrates the SPEC §9 durable queue + exponential backoff. Watch
 * logcat tag `FlowbizOnsite` (debug=true) to see the pipeline work.
 */
class DemoApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        // SPEC §2: initialize once from Application.onCreate; debug=true,
        // placeholder appId, default collectorUrl.
        Flowbiz.initialize(this, FlowbizConfig(appId = "77777", debug = true))
    }
}
