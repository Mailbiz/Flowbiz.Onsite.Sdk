package br.com.flowbiz.onsite

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Durable event queue: a JSON Lines file, one envelope entry per line, with
 * an in-memory deque of the pending lines. Appends are O(1); consumed,
 * capacity-dropped and garbage lines stay in the file as stale until
 * compaction rewrites it (at [COMPACT_STALE_THRESHOLD], whenever the queue
 * drains empty, and at load).
 *
 * A crash mid-append costs one truncated line, skipped at load. Compaction
 * writes a tmp file and renames it over the original, so a crash leaves the
 * original intact. Delivery is at-least-once (consumed lines not yet
 * compacted resend after a process death); `hash` is the collector-side
 * idempotency key.
 *
 * Confined to the SDK's serial [TaskScheduler] thread and single-process by
 * assumption, hence no locking. I/O failures degrade to memory-only
 * behavior; never throws.
 */
internal class EventQueue(
    private val file: File,
    private val capacity: Int = DEFAULT_CAPACITY,
) {

    private val pending = ArrayDeque<String>()

    /** Lines present in the file but no longer pending (consumed/dropped/garbage). */
    private var staleLines = 0

    /**
     * Set when an append failed or may have written a torn tail line.
     * While dirty, plain file appends are unsafe — a partially-written tail
     * without its newline would merge with the next appended entry into one
     * garbage line — so the next write goes through a full [compact]
     * (rewrite from [pending]) instead; a successful compaction clears it.
     */
    private var fileDirty = false

    init {
        try {
            // A leftover tmp means a compaction crashed between write and
            // rename; the original is authoritative.
            val tmp = tmpFile()
            if (tmp.exists()) tmp.delete()
            if (file.exists()) {
                file.forEachLine { line ->
                    if (line.isNotBlank() && isParseable(line)) {
                        pending.addLast(line)
                    } else if (line.isNotEmpty()) {
                        staleLines += 1
                    }
                }
                // Over-capacity file (e.g. cap lowered, or drop-oldest lines
                // resurrected after a crash): drop-oldest to the cap.
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
        get() = pending.size

    fun peek(max: Int): List<String> {
        if (max <= 0 || pending.isEmpty()) return emptyList()
        val count = minOf(max, pending.size)
        return List(count) { pending[it] }
    }

    /** At [capacity] the oldest pending entry is dropped first. */
    fun append(entry: String) {
        if (entry.isBlank() || entry.contains('\n') || entry.contains('\r')) {
            SdkLog.debug("queue rejected malformed entry")
            return
        }
        if (pending.size >= capacity) {
            pending.removeFirst()
            staleLines += 1
            SdkLog.debug("queue at capacity $capacity, dropped oldest event")
        }
        pending.addLast(entry)
        if (fileDirty) {
            // A previous append tore the tail — rewrite instead of appending.
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
                compact() // heal immediately when possible
            }
        }
        compactIfNeeded()
    }

    fun removeOldest(count: Int) {
        var remaining = minOf(count, pending.size)
        while (remaining > 0) {
            pending.removeFirst()
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
            // Original file untouched on failure; stale lines are retried at
            // the next trigger and at worst resend after a restart.
            SdkLog.debug("queue compaction failed: ${t.javaClass.simpleName}")
        }
    }

    private fun tmpFile(): File = File(file.parentFile, file.name + ".tmp")

    private fun isParseable(line: String): Boolean = try {
        JSONObject(line)
        true
    } catch (_: Throwable) {
        false
    }

    companion object {
        const val DEFAULT_CAPACITY = 1000
        const val COMPACT_STALE_THRESHOLD = 64

        fun defaultFile(context: Context, appId: String): File =
            File(File(File(context.filesDir, "flowbiz_onsite"), appId), "queue.jsonl")
    }
}
