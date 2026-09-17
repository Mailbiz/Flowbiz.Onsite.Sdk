package br.com.flowbiz.onsite

import android.content.Context
import java.util.Locale
import java.util.TimeZone

/**
 * Device-derived envelope context values (SPEC §4), injected into
 * [FlowbizCore] so tests control language/screen/timezone deterministically.
 */
internal interface DeviceContext {
    /** BCP-47 language tag, e.g. `pt-BR`. */
    val language: String

    /** Physical screen size `WxH` in pixels, e.g. `1080x2400`. */
    val screen: String

    /**
     * Device UTC offset **in minutes** at [wallMillis] (DST-correct — the
     * offset is evaluated at event time, not at initialize time).
     */
    fun timezoneOffsetMinutes(wallMillis: Long): Int
}

/**
 * Production [DeviceContext]. Language and screen are snapshotted once at
 * initialize (both effectively static for a process lifetime); the timezone
 * offset is looked up per event so DST transitions are honored. Never
 * throws (SPEC §3) — failures degrade to neutral values.
 *
 * [screen] is read from `resources.displayMetrics`, which reflects the
 * **app's display area** — in multi-window / freeform modes it can differ
 * from the physical panel size, whereas iOS reports the physical
 * `UIScreen.main.nativeBounds`. Accepted divergence: the value is
 * diagnostic envelope context, not layout input, and the `WindowManager`
 * APIs required for physical bounds are deliberately not used (API-level
 * branching for no analytical gain).
 */
internal class AndroidDeviceContext(context: Context) : DeviceContext {

    override val language: String = try {
        Locale.getDefault().toLanguageTag()
    } catch (_: Throwable) {
        "en"
    }

    override val screen: String = try {
        val metrics = context.applicationContext.resources.displayMetrics
        "${metrics.widthPixels}x${metrics.heightPixels}"
    } catch (_: Throwable) {
        "0x0"
    }

    override fun timezoneOffsetMinutes(wallMillis: Long): Int = try {
        TimeZone.getDefault().getOffset(wallMillis) / 60_000
    } catch (_: Throwable) {
        0
    }
}
