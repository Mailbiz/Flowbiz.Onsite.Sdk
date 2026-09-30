package br.com.flowbiz.onsite

import android.content.Context
import java.util.Locale
import java.util.TimeZone

internal interface DeviceContext {
    val language: String
    val screen: String
    fun timezoneOffsetMinutes(wallMillis: Long): Int
}

internal class AndroidDeviceContext(context: Context) : DeviceContext {

    override val language: String = try {
        Locale.getDefault().toLanguageTag()
    } catch (_: Throwable) {
        "en"
    }

    // The app's display area, not the physical panel iOS reports: physical bounds need API-level branching.
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
