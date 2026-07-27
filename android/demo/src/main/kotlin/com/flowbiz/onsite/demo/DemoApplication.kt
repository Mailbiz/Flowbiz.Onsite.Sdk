package com.flowbiz.onsite.demo

import android.app.Application
import com.flowbiz.onsite.Flowbiz
import com.flowbiz.onsite.FlowbizConfig

/**
 * Fake-store demo application (SPEC §14): exercises every public SDK API
 * against the production wiring (SharedPreferences, JSONL queue file,
 * lifecycle callbacks, real clock/network).
 *
 * The collectorUrl comes from BuildConfig: debug builds point at staging
 * (collector.stg.mbzlabs.me), release builds at production. Failed POSTs
 * are harmless either way — they demonstrate the SPEC §9 durable queue +
 * exponential backoff. Watch logcat tag `FlowbizOnsite` (debug=true).
 */
class DemoApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        // SPEC §2: initialize once from Application.onCreate; debug=true,
        // placeholder appId, collector selected by build type.
        Flowbiz.initialize(
            this,
            FlowbizConfig(
                appId = "77777",
                collectorUrl = BuildConfig.COLLECTOR_URL,
                debug = true,
            ),
        )
    }
}
