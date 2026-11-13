package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class EventQueueTest {

    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var file: File

    private fun queue(capacity: Int = EventQueue.DEFAULT_CAPACITY): EventQueue {
        if (!::file.isInitialized) file = File(temp.newFolder(), "queue.jsonl")
        return EventQueue(file, capacity)
    }

    private fun entry(n: Int) = """{"event":"e$n","hash":"h$n"}"""

    @Test
    fun appendPeekRoundTripPreservesOrder() {
        val q = queue()
        (1..5).forEach { q.append(entry(it)) }
        assertEquals(5, q.size)
        assertEquals((1..5).map { entry(it) }, q.peek(10).entries)
        assertEquals(5, q.size)
        assertEquals(listOf(entry(1), entry(2)), q.peek(2).entries)
    }

    @Test
    fun queueSurvivesReload() {
        val q = queue()
        (1..3).forEach { q.append(entry(it)) }
        val reloaded = EventQueue(file)
        assertEquals((1..3).map { entry(it) }, reloaded.peek(10).entries)
    }

    @Test
    fun removeConsumesTheBatchFromTheHead() {
        val q = queue()
        (1..4).forEach { q.append(entry(it)) }
        q.remove(q.peek(2))
        assertEquals(listOf(entry(3), entry(4)), q.peek(10).entries)
    }

    @Test
    fun truncatedAndGarbageLinesAreSkippedNotFatal() {
        file = File(temp.newFolder(), "queue.jsonl")
        file.writeText(
            entry(1) + "\n" +
                """{"event":"trunca""" + "\n" +
                "not json at all\n" +
                "\n" +
                entry(2) + "\n" +
                """{"event":"e3","ha"""
        )
        val q = EventQueue(file)
        assertEquals(listOf(entry(1), entry(2)), q.peek(10).entries)
        assertEquals(entry(1) + "\n" + entry(2) + "\n", file.readText())
    }

    @Test
    fun unreadableStateStartsEmpty() {
        file = File(temp.newFolder(), "queue.jsonl")
        file.mkdirs() // a directory where the file should be → read fails
        val q = EventQueue(file)
        assertEquals(0, q.size)
    }

    @Test
    fun capacityDropsOldestOnAppend() {
        val q = queue(capacity = 5)
        (1..8).forEach { q.append(entry(it)) }
        assertEquals(5, q.size)
        assertEquals((4..8).map { entry(it) }, q.peek(10).entries)
    }

    @Test
    fun overCapacityFileIsTrimmedToNewestAtLoad() {
        val q = queue(capacity = 10)
        (1..10).forEach { q.append(entry(it)) }
        val smaller = EventQueue(file, capacity = 4)
        assertEquals((7..10).map { entry(it) }, smaller.peek(10).entries)
    }

    @Test
    fun compactionTriggersAtStaleThresholdAndPreservesOrder() {
        val q = queue()
        val total = EventQueue.COMPACT_STALE_THRESHOLD + 6
        (1..total).forEach { q.append(entry(it)) }
        q.remove(q.peek(EventQueue.COMPACT_STALE_THRESHOLD))
        val expected = ((EventQueue.COMPACT_STALE_THRESHOLD + 1)..total).map { entry(it) }
        assertEquals(expected, q.peek(100).entries)
        assertEquals(expected.joinToString("") { it + "\n" }, file.readText())
    }

    @Test
    fun belowThresholdConsumedLinesStayInFileUntilCompaction() {
        val q = queue()
        (1..6).forEach { q.append(entry(it)) }
        q.remove(q.peek(2))
        assertEquals(6, file.readLines().size)
        assertEquals(listOf(entry(3), entry(4), entry(5), entry(6)), q.peek(10).entries)
    }

    @Test
    fun drainingToEmptyTruncatesTheFile() {
        val q = queue()
        (1..3).forEach { q.append(entry(it)) }
        q.remove(q.peek(3))
        assertEquals(0, q.size)
        assertEquals(0L, file.length())
    }

    @Test
    fun leftoverTmpFromCrashedCompactionIsIgnoredAndOriginalIntact() {
        file = File(temp.newFolder(), "queue.jsonl")
        file.writeText(entry(1) + "\n" + entry(2) + "\n")
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(entry(99) + "\n")
        val q = EventQueue(file)
        assertEquals(listOf(entry(1), entry(2)), q.peek(10).entries)
        assertFalse(tmp.exists())
        assertEquals(entry(1) + "\n" + entry(2) + "\n", file.readText())
    }

    @Test
    fun entriesWithRawNewlinesAreRejected() {
        val q = queue()
        q.append("{\"a\":1}\n{\"b\":2}")
        q.append("   ")
        assertEquals(0, q.size)
        q.append(entry(1))
        assertEquals(listOf(entry(1)), q.peek(10).entries)
    }

    @Test
    fun appendCreatesMissingDirectories() {
        file = File(File(temp.newFolder(), "flowbiz_onsite/77777"), "queue.jsonl")
        val q = EventQueue(file)
        q.append(entry(1))
        assertTrue(file.exists())
        assertEquals(listOf(entry(1)), EventQueue(file).peek(10).entries)
    }

    @Test
    fun failedAppendForcesRewriteSoATornTailCannotMergeWithTheNextAppend() {
        val q = queue()
        q.append(entry(1))
        val dir = file.parentFile!!
        try {
            // The read-only directory also blocks the healing compaction's tmp file.
            assertTrue(file.setWritable(false))
            assertTrue(dir.setWritable(false))
            q.append(entry(2))
            q.append(entry(3))
            assertEquals(3, q.size)
            assertEquals(listOf(entry(1)), file.readLines())
        } finally {
            dir.setWritable(true)
            file.setWritable(true)
        }
        q.append(entry(4))
        assertEquals((1..4).map { entry(it) }, EventQueue(file).peek(10).entries)
    }

    @Test
    fun theDefaultQueueLivesInTheNoBackupDirectory() {
        val noBackup = temp.newFolder("no_backup")
        val resolved = EventQueue.resolveFile(noBackup, temp.newFolder("files"), "77777")
        assertEquals(File(noBackup, "flowbiz_onsite/77777/queue.jsonl"), resolved)
    }

    @Test
    fun aQueueLeftInFilesDirByAnOlderVersionIsMovedOutOfBackup() {
        val noBackup = temp.newFolder("no_backup")
        val files = temp.newFolder("files")
        val legacy = File(files, "flowbiz_onsite/77777/queue.jsonl")
        EventQueue(legacy).apply { (1..2).forEach { append(entry(it)) } }

        val resolved = EventQueue.resolveFile(noBackup, files, "77777")

        assertEquals(listOf(entry(1), entry(2)), EventQueue(resolved).peek(10).entries)
        assertFalse(File(files, "flowbiz_onsite").exists())
    }

    @Test
    fun entriesOlderThanSevenDaysAreDroppedOnLoad() {
        val now = 1_700_000_000_000L
        fun aged(name: String, ageMillis: Long) =
            """{"event":"$name","timings":{"created_at":"${EnvelopeBuilder.isoMillis(now - ageMillis)}"}}"""
        val stale = aged("stale", EventQueue.MAX_AGE_MS + 1)
        val kept = listOf(
            aged("at-the-limit", EventQueue.MAX_AGE_MS),
            aged("fresh", MINUTE_MS),
            aged("clock-moved-back", -DAY_MS),
            entry(1), // no created_at to judge by
            """{"event":"unreadable","timings":{"created_at":"yesterday"}}""",
        )
        file = File(temp.newFolder(), "queue.jsonl")
        file.writeText((listOf(stale) + kept + stale).joinToString("") { it + "\n" })

        val q = EventQueue(file, nowMillis = { now })
        assertEquals(kept, q.peek(10).entries)
        assertEquals(kept, file.readLines())
    }

    @Test
    fun ageIsJudgedOnLoadOnlyNeverOnAppend() {
        val now = 1_700_000_000_000L
        val q = EventQueue(File(temp.newFolder(), "queue.jsonl"), nowMillis = { now })
        val old = """{"event":"old","timings":{"created_at":"${EnvelopeBuilder.isoMillis(now - 30 * DAY_MS)}"}}"""
        q.append(old)
        assertEquals(listOf(old), q.peek(10).entries)
    }

    @Test
    fun anEntryEvictedWhileItsBatchIsInFlightIsNotRemovedTwice() {
        val q = queue(capacity = 3)
        (1..3).forEach { q.append(entry(it)) }
        val inFlight = q.peek(2)
        q.append(entry(4)) // at capacity: evicts entry 1, which the batch holds
        q.remove(inFlight)
        assertEquals(listOf(entry(3), entry(4)), q.peek(10).entries)
        q.remove(inFlight)
        assertEquals(listOf(entry(3), entry(4)), q.peek(10).entries)
    }

    @Test(timeout = 20_000)
    fun appendsFromOneThreadAndRemovalsFromAnotherLoseNothing() {
        val q = queue()
        val total = 600
        val removed = mutableListOf<String>()
        val consumer = Thread {
            while (removed.size < total) {
                val batch = q.peek(7)
                removed += batch.entries
                q.remove(batch)
            }
        }
        consumer.start()
        (1..total).forEach { q.append(entry(it)) }
        consumer.join()
        assertEquals((1..total).map { entry(it) }, removed)
        assertEquals(0, q.size)
        assertEquals(emptyList<String>(), EventQueue(file).peek(10).entries)
    }
}
