package br.com.flowbiz.onsite

import android.content.Context
import java.util.Locale
import java.util.TimeZone

/** Device-derived envelope context, injected so tests control it deterministically. */
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
 * Language and screen are snapshotted at initialize; failures degrade to
 * neutral values.
 *
 * [screen] is the **app's display area**, which in multi-window / freeform
 * modes can differ from the physical panel iOS reports. Accepted: it is
 * diagnostic context, and the `WindowManager` APIs for physical bounds need
 * API-level branching for no analytical gain.
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
