package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/**
 * SPEC §11.1 item 3 persistence: `utm_data` (ordered `[key, value]` pairs)
 * plus `utm_expires_at_wall_ms`, a 30-day wall-clock expiry valid while
 * `expires − now > 0` (web `StorageFactory`); an expired or corrupt entry is
 * removed — both keys — and reads as empty. While the SDK is disabled only
 * [UtmStore.purgeIfExpired] runs, which reads nothing but the expiry.
 */
class UtmStoreTest {

    private val pairs = listOf("utm_campaign" to "c1", "utm_source" to "flowbiz", "utm_journey" to "16")

    private fun assertNoUtmKeys(store: FakeKeyValueStore, message: String = "") {
        assertFalse("$message: utm_data left behind", store.values.containsKey(StorageKeys.UTM_DATA))
        assertFalse("$message: expiry left behind", store.values.containsKey(StorageKeys.UTM_EXPIRES_AT_WALL_MS))
    }

    @Test
    fun wireNamesAndTtlMatchTheContract() {
        assertEquals("utm_data", StorageKeys.UTM_DATA)
        assertEquals("utm_expires_at_wall_ms", StorageKeys.UTM_EXPIRES_AT_WALL_MS)
        assertEquals(2_592_000_000L, UtmStore.TTL_MS) // web thirtyDays * 1000
        assertEquals(30 * DAY_MS, UtmStore.TTL_MS)
    }

    @Test
    fun saveThenLoadKeepsMergeOrderAndExpiresThirtyDaysFromNow() {
        val kv = FakeKeyValueStore()
        val clock = FakeClock()
        val store = UtmStore(kv, clock)
        store.save(pairs)
        assertEquals(pairs, store.load())
        assertEquals(clock.wall + 30 * DAY_MS, kv.values[StorageKeys.UTM_EXPIRES_AT_WALL_MS])
        assertEquals(
            """[["utm_campaign","c1"],["utm_source","flowbiz"],["utm_journey","16"]]""",
            kv.values[StorageKeys.UTM_DATA],
        )
    }

    @Test
    fun missingEntryReadsEmptyAndWritesNothing() {
        val kv = FakeKeyValueStore()
        assertEquals(emptyList<Pair<String, String>>(), UtmStore(kv, FakeClock()).load())
        assertTrue(kv.values.isEmpty())
    }

    @Test
    fun persistsAcrossStoreInstances() {
        val kv = FakeKeyValueStore()
        val clock = FakeClock()
        UtmStore(kv, clock).save(pairs)
        clock.advance(29 * DAY_MS)
        assertEquals(pairs, UtmStore(kv, clock).load())
    }

    /** Boundary: valid at `expires − 1 ms`, expired at exactly `expires` (web `expires − now > 0`). */
    @Test
    fun validOneMillisecondBeforeExpiryAndExpiredExactlyAtIt() {
        val kv = FakeKeyValueStore()
        val clock = FakeClock()
        val store = UtmStore(kv, clock)
        store.save(pairs)

        clock.advance(UtmStore.TTL_MS - 1)
        assertEquals(pairs, store.load())

        clock.advance(1)
        assertEquals(emptyList<Pair<String, String>>(), store.load())
        assertNoUtmKeys(kv, "expired")
    }

    /**
     * SPEC §3 corrupt persisted state is discarded silently: every shape
     * the SDK never writes removes both keys and reads as empty.
     */
    @Test
    fun corruptEntriesAreRemovedAndReadEmpty() {
        val clock = FakeClock()
        val validData = """[["utm_source","flowbiz"]]"""
        val validExpiry: Long = clock.wall + DAY_MS
        val cases: List<Triple<String, Any?, Any?>> = listOf(
            Triple("data missing", null, validExpiry),
            Triple("expiry missing", validData, null),
            Triple("data wrong type", 42L, validExpiry),
            Triple("expiry wrong type", validData, "$validExpiry"),
            Triple("unparseable", "not json", validExpiry),
            Triple("object, not array", """{"utm_source":"flowbiz"}""", validExpiry),
            Triple("empty array", "[]", validExpiry),
            Triple("element not an array", """["utm_source"]""", validExpiry),
            Triple("null element", """[["utm_source","a"],null]""", validExpiry),
            Triple("pair too short", """[["utm_source"]]""", validExpiry),
            Triple("pair too long", """[["utm_source","a","b"]]""", validExpiry),
            Triple("non-string value", """[["utm_source",1]]""", validExpiry),
            Triple("non-string key", """[[1,"a"]]""", validExpiry),
            Triple("key outside the allowlist", """[["utm_term","a"]]""", validExpiry),
            Triple("utm_flow_params is never kept", """[["utm_flow_params","a|b|c"]]""", validExpiry),
            Triple("empty value", """[["utm_source",""]]""", validExpiry),
            Triple("duplicate key", """[["utm_source","a"],["utm_source","b"]]""", validExpiry),
            // Not JSON at all, though a lenient reader (org.json) takes it:
            Triple("trailing garbage", """[["utm_source","a"]] trailing""", validExpiry),
            Triple("extra closing bracket", """[["utm_source","a"]]]""", validExpiry),
            Triple("unquoted strings", """[[utm_source,a]]""", validExpiry),
            Triple("single-quoted strings", """[['utm_source','a']]""", validExpiry),
            Triple("trailing comma", """[["utm_source","a"],]""", validExpiry),
            Triple("missing comma", """[["utm_source" "a"]]""", validExpiry),
            Triple("semicolon separator", """[["utm_source";"a"]]""", validExpiry),
            Triple("raw control character", "[[\"utm_source\",\"a\u0001\"]]", validExpiry),
            Triple("unknown escape", """[["utm_source","a\x41"]]""", validExpiry),
            Triple("short unicode escape", """[["utm_source","\u41"]]""", validExpiry),
            Triple("signed unicode escape", """[["utm_source","\u+041"]]""", validExpiry),
            Triple("non-ASCII hex digits", "[[\"utm_source\",\"\\u\uff10\uff10\uff14\uff11\"]]", validExpiry),
            Triple("unterminated string", """[["utm_source","a]]""", validExpiry),
            Triple("two top-level values", """[["utm_source","a"]][]""", validExpiry),
        )
        for ((name, data, expiry) in cases) {
            val kv = FakeKeyValueStore()
            data?.let { kv.values[StorageKeys.UTM_DATA] = it }
            expiry?.let { kv.values[StorageKeys.UTM_EXPIRES_AT_WALL_MS] = it }
            assertEquals(name, emptyList<Pair<String, String>>(), UtmStore(kv, clock).load())
            assertNoUtmKeys(kv, name)
        }
    }

    /**
     * The reader is strict JSON, not "exactly our bytes": any well-formed
     * JSON of the right shape reads — insignificant whitespace, `\/`,
     * uppercase hex, escaped ASCII, raw non-ASCII (the iOS store's own
     * format) — like the iOS store's `JSONDecoder`, so both platforms keep
     * and discard the same stored text.
     */
    @Test
    fun anyWellFormedJsonOfTheStoredShapeReads() {
        val clock = FakeClock()
        val cases = listOf(
            " [ [ \"utm_source\" , \"a\" ] ,\n\t[\"utm_medium\",\"b\"]\r\n] " to
                listOf("utm_source" to "a", "utm_medium" to "b"),
            """[["utm_source","a\/b"]]""" to listOf("utm_source" to "a/b"),
            """[["utm_source","\u00E7\u00e7"]]""" to listOf("utm_source" to "çç"),
            """[["\u0075tm_source","\"\\\b\f\n\r\t"]]""" to listOf("utm_source" to "\"\\\b\u000c\n\r\t"),
            """[["utm_campaign","promoção 😀"]]""" to listOf("utm_campaign" to "promoção 😀"),
            """[["utm_source","\ud83d\ude00"]]""" to listOf("utm_source" to "😀"),
        )
        for ((data, expected) in cases) {
            val kv = FakeKeyValueStore().apply {
                values[StorageKeys.UTM_DATA] = data
                values[StorageKeys.UTM_EXPIRES_AT_WALL_MS] = clock.wall + DAY_MS
            }
            assertEquals(data, expected, UtmStore(kv, clock).load())
            assertEquals(data, kv.values[StorageKeys.UTM_DATA])
        }
    }

    /**
     * Seeded fuzz of the strict reader: any value — every UTF-16 unit,
     * lone surrogates included — round-trips through [UtmStore.save]'s
     * ASCII-only text, and any one-character mutation of that text reads
     * either as a valid set or as nothing with both keys removed; it never
     * throws.
     */
    @Test
    fun randomValuesRoundTripAndMutatedTextNeverEscapes() {
        val random = Random(20260923)
        val clock = FakeClock()
        val noise = "[]\",\\ u0aF:{}\u0001\u00e7"
        repeat(3_000) { round ->
            val kv = FakeKeyValueStore()
            val store = UtmStore(kv, clock)
            val written = UtmLinkParser.ALLOWLIST.shuffled(random)
                .take(random.nextInt(1, UtmLinkParser.ALLOWLIST.size + 1))
                .map { key -> key to buildString { repeat(random.nextInt(1, 6)) { append(random.nextInt(0, 0x10000).toChar()) } } }
            store.save(written)
            assertEquals("round $round", written, store.load())

            val stored = kv.values[StorageKeys.UTM_DATA] as String
            val at = random.nextInt(stored.length)
            kv.values[StorageKeys.UTM_DATA] = StringBuilder(stored).apply {
                when (random.nextInt(3)) {
                    0 -> deleteCharAt(at)
                    1 -> insert(at, noise[random.nextInt(noise.length)])
                    else -> setCharAt(at, noise[random.nextInt(noise.length)])
                }
            }.toString()
            val read = store.load()
            if (read.isEmpty()) {
                assertNoUtmKeys(kv, "round $round")
            } else {
                assertTrue(read.all { (key, value) -> key in UtmLinkParser.ALLOWLIST && value.isNotEmpty() })
                assertEquals(read.size, read.map { it.first }.toSet().size)
            }
        }
    }

    /**
     * SPEC §11.1 item 4 / §12 disabled-state purge: decided on
     * `utm_expires_at_wall_ms` alone — `utm_data` is never read, so a
     * corrupt one (which [UtmStore.load] would discard) changes nothing —
     * and removes both keys once expired, on the same `expires − now > 0`
     * boundary as [UtmStore.load].
     */
    @Test
    fun purgeIfExpiredReadsOnlyTheExpiryAndRemovesBothKeysOnceExpired() {
        val clock = FakeClock()
        fun store(data: Any?, expiry: Any?) = FakeKeyValueStore().apply {
            data?.let { values[StorageKeys.UTM_DATA] = it }
            expiry?.let { values[StorageKeys.UTM_EXPIRES_AT_WALL_MS] = it }
        }

        for ((name, expiry) in listOf("exactly at expiry" to clock.wall, "long expired" to Long.MIN_VALUE)) {
            val kv = store("{not json", expiry)
            UtmStore(kv, clock).purgeIfExpired()
            assertNoUtmKeys(kv, name)
            assertFalse(name, StorageKeys.UTM_DATA in kv.reads)
        }
        val expiryAlone = store(null, clock.wall)
        UtmStore(expiryAlone, clock).purgeIfExpired()
        assertNoUtmKeys(expiryAlone, "expired expiry without utm_data")

        // Live (1 ms left), no expiry, or a wrong-typed one (reads as absent): untouched.
        val untouched = listOf(
            "live, corrupt utm_data" to store("{not json", clock.wall + 1),
            "utm_data without expiry" to store("""[["utm_source","a"]]""", null),
            "wrong-typed expiry" to store("""[["utm_source","a"]]""", "${clock.wall}"),
            "nothing stored" to store(null, null),
        )
        for ((name, kv) in untouched) {
            val before = kv.values.toMap()
            UtmStore(kv, clock).purgeIfExpired()
            assertEquals(name, before, kv.values)
            assertFalse(name, StorageKeys.UTM_DATA in kv.reads)
        }
    }

    /** A wall clock at the far end of the range saturates the expiry instead of wrapping into the past. */
    @Test
    fun expirySaturatesInsteadOfOverflowing() {
        val kv = FakeKeyValueStore()
        val clock = FakeClock(wall = Long.MAX_VALUE - UtmStore.TTL_MS + 1)
        val store = UtmStore(kv, clock)
        store.save(pairs)
        assertEquals(Long.MAX_VALUE, kv.values[StorageKeys.UTM_EXPIRES_AT_WALL_MS])
        assertEquals(pairs, store.load())
    }

    /**
     * Values are stored exactly as decoded — control characters, U+FFFE,
     * lone surrogates, emoji — yet the persisted string is ASCII-only
     * (`\uXXXX` escapes), so the SharedPreferences XML file never carries a
     * character XML 1.0 cannot represent.
     */
    @Test
    fun anyDecodedValueRoundTripsThroughAnAsciiOnlyStoredString() {
        val kv = FakeKeyValueStore()
        val store = UtmStore(kv, FakeClock())
        val hostile = listOf(
            "utm_source" to "\u0000\u001f\"\\/",
            "utm_medium" to "\ufffe\uffff\u007f",
            "utm_campaign" to "a\ud800b\udc00ç😀",
        )
        store.save(hostile)
        val stored = kv.values[StorageKeys.UTM_DATA] as String
        assertTrue(stored, stored.all { it.code in 0x20..0x7e })
        assertEquals(hostile, store.load())
    }
}
