package br.com.flowbiz.onsite

/**
 * Minimal internal log seam. The transport components (queue, sender,
 * flusher) log through this so they stay free of `android.util.Log` — JVM
 * unit tests run them without Robolectric. Slice 4 wires [sink] to
 * `Log.d`-style output when `debug` is enabled; until then logging is a
 * no-op.
 *
 * Never throws: a misbehaving sink is swallowed (SPEC §3). Callers must
 * never log PII (SPEC §12) — messages carry counts, codes and reasons only.
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
