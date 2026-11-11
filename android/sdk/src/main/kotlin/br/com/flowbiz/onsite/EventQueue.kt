package br.com.flowbiz.onsite

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.Instant

// At-least-once: removed lines stay in the file until compaction, so a crash can re-send delivered events
// (the collector does not deduplicate on `hash`).
// Shared by two threads: the SDK thread appends while the transport thread peeks, sends and removes.
internal class EventQueue(
    private val file: File,
    private val capacity: Int = DEFAULT_CAPACITY,
    nowMillis: () -> Long = System::currentTimeMillis,
) {

    /** A prefix of the queue as [peek] saw it. */
    class Batch internal constructor(val entries: List<String>, internal val endSequence: Long)

    private val lock = Any()

    private val pending = ArrayDeque<String>()

    // Sequence number of the head: entries evicted at capacity while a batch is in flight are not removed twice.
    private var headSequence = 0L

    private var staleLines = 0

    // After a failed append the tail may be torn: appending would merge the next entry into it.
    private var fileDirty = false

    init {
        try {
            // A leftover tmp is a compaction that crashed before the rename; the original is authoritative.
            val tmp = tmpFile()
            if (tmp.exists()) tmp.delete()
            if (file.exists()) {
                // An event delivered weeks late would move its cart's last update: created_at is what the backend reads.
                val oldest = nowMillis() - MAX_AGE_MS
                var expired = 0
                file.forEachLine { line ->
                    val createdAt = if (line.isBlank()) null else createdAtMillis(line)
                    when {
                        createdAt == null -> if (line.isNotEmpty()) staleLines += 1
                        createdAt < oldest -> expired += 1
                        else -> pending.addLast(line)
                    }
                }
                if (expired > 0) {
                    staleLines += expired
                    SdkLog.debug("queue dropped $expired events older than ${MAX_AGE_MS / 86_400_000} days")
                }
                while (pending.size > capacity) {
                    pending.removeFirst()
                    staleLines += 1
                }
                if (staleLines > 0) compact()
            }
        } catch (t: Throwable) {
            SdkLog.debug("queue load failed, starting empty: ${t.javaClass.simpleName}")
            pending.clear()
            staleLines = 0
        }
    }

    val size: Int
        get() = synchronized(lock) { pending.size }

    fun peek(max: Int): Batch = synchronized(lock) {
        val count = minOf(maxOf(max, 0), pending.size)
        Batch(List(count) { pending[it] }, headSequence + count)
    }

    fun append(entry: String) = synchronized(lock) {
        if (entry.isBlank() || entry.contains('\n') || entry.contains('\r')) {
            SdkLog.debug("queue rejected malformed entry")
            return
        }
        if (pending.size >= capacity) {
            pending.removeFirst()
            headSequence += 1
            staleLines += 1
            SdkLog.debug("queue at capacity $capacity, dropped oldest event")
        }
        pending.addLast(entry)
        if (fileDirty) {
            compact()
        } else {
            try {
                file.parentFile?.mkdirs()
                FileOutputStream(file, true).use { stream ->
                    stream.write((entry + "\n").toByteArray(Charsets.UTF_8))
                }
            } catch (t: Throwable) {
                SdkLog.debug("queue append I/O failed: ${t.javaClass.simpleName}")
                fileDirty = true
                compact()
            }
        }
        compactIfNeeded()
    }

    /** Removes what is still queued of [batch]. */
    fun remove(batch: Batch) = synchronized(lock) {
        var remaining = minOf(batch.endSequence - headSequence, pending.size.toLong())
        while (remaining > 0) {
            pending.removeFirst()
            headSequence += 1
            staleLines += 1
            remaining -= 1
        }
        compactIfNeeded()
    }

    private fun compactIfNeeded() {
        if (staleLines >= COMPACT_STALE_THRESHOLD || (staleLines > 0 && pending.isEmpty())) {
            compact()
        }
    }

    private fun compact() {
        try {
            file.parentFile?.mkdirs()
            val tmp = tmpFile()
            FileOutputStream(tmp).use { stream ->
                for (line in pending) {
                    stream.write((line + "\n").toByteArray(Charsets.UTF_8))
                }
            }
            Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
            staleLines = 0
            fileDirty = false
        } catch (t: Throwable) {
            SdkLog.debug("queue compaction failed: ${t.javaClass.simpleName}")
        }
    }

    private fun tmpFile(): File = File(file.parentFile, file.name + ".tmp")

    // Null when the line is not an entry; an entry without a readable created_at never expires.
    private fun createdAtMillis(line: String): Long? = try {
        val createdAt = JSONObject(line).optJSONObject("timings")?.optString("created_at")
        try {
            if (createdAt.isNullOrEmpty()) Long.MAX_VALUE else Instant.parse(createdAt).toEpochMilli()
        } catch (_: Throwable) {
            Long.MAX_VALUE
        }
    } catch (_: Throwable) {
        null
    }

    companion object {
        const val DEFAULT_CAPACITY = 1000
        const val COMPACT_STALE_THRESHOLD = 64

        // Applied when the queue loads. The web out-queue has no max age; 7 days is the SDK's own rule.
        const val MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000L

        fun defaultFile(context: Context, appId: String): File =
            resolveFile(context.noBackupFilesDir, context.filesDir, appId)

        // Out of Auto Backup: a queue restored on reinstall or a new device would re-send old events.
        // Takes over the queue 0.1.x kept in filesDir.
        fun resolveFile(noBackupDir: File, legacyDir: File, appId: String): File {
            val file = queueFile(noBackupDir, appId)
            val legacy = queueFile(legacyDir, appId)
            if (legacy.exists() && !file.exists()) {
                file.parentFile?.mkdirs()
                if (!legacy.renameTo(file)) return legacy
            }
            legacy.parentFile?.takeIf { it.exists() }?.let { appDir ->
                appDir.deleteRecursively()
                appDir.parentFile?.delete() // only if no other appId's queue is left
            }
            return file
        }

        private const val ROOT_DIR = "flowbiz_onsite"

        fun stateDir(dir: File, appId: String) = File(File(dir, ROOT_DIR), appId)

        private fun queueFile(dir: File, appId: String) = File(stateDir(dir, appId), "queue.jsonl")
    }
}
