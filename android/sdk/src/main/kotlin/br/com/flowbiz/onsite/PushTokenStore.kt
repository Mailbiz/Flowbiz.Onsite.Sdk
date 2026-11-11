package br.com.flowbiz.onsite

import android.content.Context
import java.io.File

// In a file out of Auto Backup, not in the preferences: a token restored on another phone is not that
// phone's, and logout() would send the removal of the old phone's token. Confined to the SDK thread.
internal class PushTokenStore(
    fileFactory: () -> File,
    private val legacy: KeyValueStore,
) {

    // Lazy: resolving the directory may touch the disk, which must not happen on the caller's main thread.
    private val file: File by lazy(fileFactory)
    private var migrated = false

    val token: String?
        get() = guarded("read") {
            migrate()
            file.takeIf { it.isFile }?.readText(Charsets.UTF_8)?.takeIf { it.isNotEmpty() }
        }

    fun set(token: String) {
        guarded("write") {
            migrate()
            write(token)
        }
    }

    fun clear() {
        guarded("clear") { migrate() }
        guarded("clear") {
            // Also a token the migration could not move: it must not come back at the next start.
            legacy.remove(StorageKeys.PUSH_TOKEN)
            if (file.isFile) file.delete()
        }
    }

    // 0.1.x kept the token in the preferences. Once: a token found there later came from a restored backup.
    // A write that throws keeps it there for the next start.
    private fun migrate() {
        if (migrated) return
        migrated = true
        val old = legacy.getString(StorageKeys.PUSH_TOKEN)
        if (old != null && !file.exists()) write(old)
        legacy.remove(StorageKeys.PUSH_TOKEN)
    }

    private fun write(token: String) {
        file.parentFile?.mkdirs()
        file.writeText(token, Charsets.UTF_8)
    }

    private fun <T> guarded(action: String, block: () -> T?): T? = try {
        block()
    } catch (t: Throwable) {
        SdkLog.debug("push token $action failed: ${t.javaClass.simpleName}")
        null
    }

    companion object {
        fun defaultFile(context: Context, appId: String): File =
            File(EventQueue.stateDir(context.noBackupFilesDir, appId), "push_token")
    }
}
