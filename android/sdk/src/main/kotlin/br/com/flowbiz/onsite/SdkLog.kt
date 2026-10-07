package br.com.flowbiz.onsite

internal object SdkLog {

    @Volatile
    var sink: ((String) -> Unit)? = null

    // Never log PII: messages carry counts, codes and reasons only.
    fun debug(message: String) {
        try {
            sink?.invoke(message)
        } catch (_: Throwable) {
        }
    }
}
