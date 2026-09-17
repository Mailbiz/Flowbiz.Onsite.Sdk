package br.com.flowbiz.onsite

/**
 * In-memory [KeyValueStore] for unit tests (real SharedPreferences needs a
 * device/Robolectric — deliberately not used). Mimics the hardened
 * [SharedPreferencesStore] semantics: a value read back as the wrong type
 * degrades to null, never a throw. [values] is exposed so tests can plant
 * corrupt entries and inspect persistence directly.
 */
internal class FakeKeyValueStore : KeyValueStore {

    val values = mutableMapOf<String, Any>()

    override fun getString(key: String): String? = values[key] as? String
    override fun getInt(key: String): Int? = values[key] as? Int
    override fun getLong(key: String): Long? = values[key] as? Long
    override fun getBoolean(key: String): Boolean? = values[key] as? Boolean

    override fun putString(key: String, value: String) { values[key] = value }
    override fun putInt(key: String, value: Int) { values[key] = value }
    override fun putLong(key: String, value: Long) { values[key] = value }
    override fun putBoolean(key: String, value: Boolean) { values[key] = value }

    override fun remove(key: String) { values.remove(key) }
}

/** Manually-driven [Clock]; monotonic and wall time are independently mutable. */
internal class FakeClock(
    var monotonic: Long = 500_000L,
    // 2023-11-14T22:13:20 UTC
    var wall: Long = 1_700_000_000_000L,
) : Clock {

    override fun monotonicMillis(): Long = monotonic
    override fun wallMillis(): Long = wall

    /** Real time passing: both clocks advance in lockstep. */
    fun advance(millis: Long) {
        monotonic += millis
        wall += millis
    }
}

internal const val MINUTE_MS = 60_000L
