package br.com.flowbiz.onsite

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Build

// What outlives the app's time in the foreground: a flush of the queue once the network is back.
internal interface BackgroundFlush {
    /** Whether the system took the job: a refused one must not count as held. */
    fun schedule(): Boolean

    fun cancel()

    /** Whether the system holds the job, also one a previous process of the app scheduled. */
    fun isPending(): Boolean

    object None : BackgroundFlush {
        override fun schedule() = false
        override fun cancel() = Unit
        override fun isPending() = false
    }
}

// The platform JobScheduler, not WorkManager: the SDK has no dependencies. The job is not persisted
// (that needs RECEIVE_BOOT_COMPLETED), so a reboot or a force stop drops it; the next app open flushes.
internal class JobSchedulerBackgroundFlush(context: Context) : BackgroundFlush {

    private val appContext = context.applicationContext

    override fun schedule(): Boolean =
        try {
            val job = JobInfo.Builder(JOB_ID, ComponentName(appContext, FlowbizFlushJobService::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .build()
            // Same id: replaces the job a previous backgrounding left.
            val accepted = scheduler()?.schedule(job) == JobScheduler.RESULT_SUCCESS
            if (!accepted) SdkLog.debug("background flush job refused")
            accepted
        } catch (t: Throwable) {
            SdkLog.debug("background flush job not scheduled: ${t.javaClass.simpleName}")
            false
        }

    override fun cancel() {
        try {
            scheduler()?.cancel(JOB_ID)
            SdkLog.debug("background flush job cancelled")
        } catch (t: Throwable) {
            SdkLog.debug("background flush job not cancelled: ${t.javaClass.simpleName}")
        }
    }

    override fun isPending(): Boolean =
        try {
            scheduler()?.getPendingJob(JOB_ID) != null
        } catch (t: Throwable) {
            SdkLog.debug("background flush job not looked up: ${t.javaClass.simpleName}")
            false
        }

    // Job ids are shared by the whole app; a namespace (Android 14+) keeps this one from the host's.
    private fun scheduler(): JobScheduler? {
        val scheduler = appContext.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler
        return if (Build.VERSION.SDK_INT >= 34) scheduler?.forNamespace(NAMESPACE) else scheduler
    }

    companion object {
        const val NAMESPACE = "br.com.flowbiz.onsite"

        // "FLBZ": below Android 14 it must not collide with a job id of the host app.
        const val JOB_ID = 0x464C425A
    }
}

/** Declared in the SDK's manifest; started by the system, never by the host app. */
class FlowbizFlushJobService : JobService() {

    // The process may have been started for this job: without a core (initialize not in Application.onCreate)
    // there is nothing to flush with.
    override fun onStartJob(params: JobParameters?): Boolean =
        Flowbiz.backgroundFlush { queueEmpty -> jobFinished(params, !queueEmpty) }

    // Stopped by the system, the network gone again: have it run once more.
    override fun onStopJob(params: JobParameters?): Boolean = true
}
