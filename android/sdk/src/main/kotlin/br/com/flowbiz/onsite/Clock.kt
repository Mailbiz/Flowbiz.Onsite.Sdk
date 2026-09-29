package br.com.flowbiz.onsite

internal interface Clock {
    /** Arbitrary epoch, immune to wall-clock changes, reset on restart: drives in-process expiry. */
    fun monotonicMillis(): Long
    /** Epoch millis: envelope `timings` and the persisted restart fallback. */
    fun wallMillis(): Long
}
