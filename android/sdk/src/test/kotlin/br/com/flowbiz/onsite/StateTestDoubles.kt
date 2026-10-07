package br.com.flowbiz.onsite

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

internal class FakeClock(
    var monotonic: Long = 500_000L,
    var wall: Long = 1_700_000_000_000L,
) : Clock {

    override fun monotonicMillis(): Long = monotonic
    override fun wallMillis(): Long = wall

    fun advance(millis: Long) {
        monotonic += millis
        wall += millis
    }
}

internal const val MINUTE_MS = 60_000L
internal const val DAY_MS = 24 * 60 * MINUTE_MS
