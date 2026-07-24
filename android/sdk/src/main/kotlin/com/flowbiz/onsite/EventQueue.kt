package com.flowbiz.onsite

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Durable event queue (SPEC §9): JSON Lines file, one serialized envelope
 * entry per line, append-only.
 *
 * ## Model
 * An in-memory deque of pending lines mirrors the file; the file may
 * additionally contain **stale** lines (consumed after a successful flush,
 * dropped at the capacity cap, or unparseable garbage) that are purged only
 * at compaction. Appends are O(1) (open-append-close); consumption is
 * logical (head of the deque) until compaction rewrites the file.
 *
 * ## Durability & crash behavior
 * - A crash mid-append costs one truncated line; unparseable/blank lines
 *   are skipped (and counted stale) at load, never fatal (SPEC §3/§9).
 * - Compaction writes `queue.jsonl.tmp` then atomically renames it over the
 *   original ([Files.move] + `REPLACE_EXISTING`, a same-directory rename) —
 *   a crash between write and rename leaves the original intact; the
 *   leftover tmp is deleted at next load.
 * - Delivery is at-least-once: consumed-but-not-yet-compacted lines (and,
 *   rarely, capacity-dropped ones) resend after a process death. `hash` is
 *   the collector-side idempotency key (SPEC §9).
 *
 * ## Compaction trigger
 * Compacts when the stale-line count reaches [COMPACT_STALE_THRESHOLD], and
 * eagerly whenever the queue drains empty (a cheap truncate — the common
 * "successful flush" case, per SPEC §9), and at load when any stale line
 * was found.
 *
 * ## Concurrency
 * **Thread-confined** to the SDK's serial [TaskScheduler] thread — no
 * internal locking, no file locking. Single-process access is a SPEC §9
 * assumption. Never throws: I/O failures log and degrade to memory-only
 * behavior for the session.
 *
 * The backing [file] is injected (tests use temp dirs); [defaultFile] is the
 * only member touching `android.*`.
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

    /** Number of pending (not yet delivered) entries. */
    val size: Int
        get() = pending.size

    /** Oldest-first snapshot of up to [max] pending entries; the queue is unchanged. */
    fun peek(max: Int): List<String> {
        if (max <= 0 || pending.isEmpty()) return emptyList()
        val count = minOf(max, pending.size)
        return List(count) { pending[it] }
    }

    /**
     * Appends one serialized envelope entry. At [capacity] the oldest
     * pending entry is dropped first (SPEC §9 drop-oldest). Entries
     * containing raw newlines are rejected (canonical JSON never has them —
     * defensive only).
     */
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

    /** Removes the [count] oldest pending entries (a delivered or poison batch). */
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

    /** Rewrites the file to exactly the pending entries (write tmp, atomic rename). */
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
        /** SPEC §9: 1000 events, drop-oldest. Internal constant, not a knob. */
        const val DEFAULT_CAPACITY = 1000

        /** Stale lines tolerated in the file before a rewrite is forced. */
        const val COMPACT_STALE_THRESHOLD = 64

        /**
         * Production queue location:
         * `<filesDir>/flowbiz_onsite/<appId>/queue.jsonl` (app-private; the
         * only `android.*` touchpoint in this class).
         */
        fun defaultFile(context: Context, appId: String): File =
            File(File(File(context.filesDir, "flowbiz_onsite"), appId), "queue.jsonl")
    }
}
