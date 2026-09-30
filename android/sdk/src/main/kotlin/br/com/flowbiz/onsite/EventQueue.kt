package br.com.flowbiz.onsite

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption

// At-least-once: removed lines stay in the file until compaction; `hash` is the collector's idempotency key.
internal class EventQueue(
    private val file: File,
    private val capacity: Int = DEFAULT_CAPACITY,
) {

    private val pending = ArrayDeque<String>()

    private var staleLines = 0

    // After a failed append the tail may be torn: appending would merge the next entry into it.
    private var fileDirty = false

    init {
        try {
            // A leftover tmp is a compaction that crashed before the rename; the original is authoritative.
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
