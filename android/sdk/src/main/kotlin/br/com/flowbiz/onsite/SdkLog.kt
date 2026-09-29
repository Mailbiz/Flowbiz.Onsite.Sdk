package br.com.flowbiz.onsite

/**
 * Log seam free of `android.util.Log`, so JVM unit tests need no
 * Robolectric; [sink] is set only when `debug` is on. Callers must never
 * log PII — messages carry counts, codes and reasons only.
 */
internal object SdkLog {

    @Volatile
    var sink: ((String) -> Unit)? = null

    fun debug(message: String) {
        try {
            sink?.invoke(message)
        } catch (_: Throwable) {
            // A broken log sink must never break the SDK.
        }
    }
}
