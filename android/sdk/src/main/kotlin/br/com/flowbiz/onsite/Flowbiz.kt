package br.com.flowbiz.onsite

import android.app.Activity
import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.util.Log
import java.util.concurrent.Executors

/** Every call is thread-safe, returns at once and never throws; before [initialize] only the decoders work. */
object Flowbiz {

    // Reference parameters are nullable on purpose: a non-null one throws on a Java null before the catch-all.

    private const val LOG_TAG = "FlowbizOnsite"

    @Volatile
    private var core: FlowbizCore? = null

    /** Call once, from `Application.onCreate`; later calls are ignored. */
    @JvmStatic
    fun initialize(context: Context?, config: FlowbizConfig?) {
        try {
            if (context == null || config == null) {
                SdkLog.debug("Flowbiz.initialize ignored: null ${if (context == null) "context" else "config"}")
                return
            }
            synchronized(this) {
                if (core != null) {
                    SdkLog.debug("initialize ignored: already initialized (first config wins)")
                    return
                }
                if (config.debug) {
                    SdkLog.sink = { message -> Log.d(LOG_TAG, message) }
                }
                val sanitized = ConfigSanitizer.sanitize(config) ?: return
                val appContext = context.applicationContext
                val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
                    Thread(runnable, "flowbiz-onsite").apply { isDaemon = true }
                }
                val created = FlowbizCore(
                    config = sanitized,
                    store = SharedPreferencesStore(appContext, sanitized.appId),
                    queueFactory = { EventQueue(EventQueue.defaultFile(appContext, sanitized.appId)) },
                    sender = HttpUrlSender(sanitized.collectorUrl, FlowbizCore.PLATFORM),
                    scheduler = ExecutorTaskScheduler(executor),
                    clock = AndroidClock,
                    deviceContext = AndroidDeviceContext(appContext),
                    reachability = AndroidReachability(appContext),
                )
                core = created
                val application = appContext as? Application
                if (application != null) {
                    application.registerActivityLifecycleCallbacks(
                        ForegroundTracker(created::onForeground, created::onBackground)
                    )
                } else {
                    SdkLog.debug("application context is not an Application; lifecycle tracking disabled")
                }
                SdkLog.debug("initialized (appId=${sanitized.appId})")
            }
        } catch (t: Throwable) {
            SdkLog.debug("initialize failed: ${t.javaClass.simpleName}")
        }
    }

    @JvmStatic
    fun track(event: Event?) {
        if (event == null) {
            SdkLog.debug("Flowbiz.track ignored: null event")
            return
        }
        withCore("track") { it.track(event) }
    }

    /** Clears the user identity, starts a new session and removes the registered push token. */
    @JvmStatic
    fun logout() = withCore("logout") { it.logout() }

    /** Opt-out switch, persisted across launches; while disabled nothing is tracked or sent (a push token and links' UTMs are kept). */
    @JvmStatic
    fun setEnabled(enabled: Boolean) = withCore("setEnabled") { it.setEnabled(enabled) }

    @JvmStatic
    fun flush() = withCore("flush") { it.flush() }

    /** Relays the push token; while disabled it is kept and synced on re-enable. [logout] removes it; blank is ignored. */
    @JvmStatic
    fun setPushToken(token: String?) {
        if (token.isNullOrBlank()) {
            SdkLog.debug("Flowbiz.setPushToken ignored: null/blank token")
            return
        }
        withCore("setPushToken") { it.setPushToken(token) }
    }

    @JvmStatic
    fun removePushToken() = withCore("removePushToken") { it.removePushToken() }

    /** Decodes a Flowbiz push (null if not ours); captures no UTMs, so on tap call [handlePushOpened]. */
    @JvmStatic
    fun handlePush(payload: Map<String, String>?): FlowbizPush? = try {
        payload?.get(PushPayloadParser.MARKER_KEY)?.let(PushPayloadParser::parse)
    } catch (t: Throwable) {
        null
    }

    /** Decodes a cart-recovery link and captures its campaign UTMs; forward every incoming link. */
    @JvmStatic
    fun handleLink(url: Uri?): RecoveryPayload? = try {
        handleLink(url?.toString(), core)
    } catch (t: Throwable) {
        null
    }

    internal fun handleLink(link: String?, current: FlowbizCore?): RecoveryPayload? {
        if (link == null) return null
        current?.captureUtm(link)
        return RecoveryLinkParser.parse(link, current?.config?.appId)
    }

    /** Call on notification tap: [handleLink] over the push's raw deep link. */
    @JvmStatic
    fun handlePushOpened(push: FlowbizPush?): RecoveryPayload? = try {
        handleLink(push?.deepLinkString, core)
    } catch (t: Throwable) {
        null
    }

    private inline fun withCore(name: String, action: (FlowbizCore) -> Unit) {
        try {
            val current = core
            if (current == null) {
                SdkLog.debug("Flowbiz.$name ignored: initialize was not called")
                return
            }
            action(current)
        } catch (t: Throwable) {
            SdkLog.debug("Flowbiz.$name failed: ${t.javaClass.simpleName}")
        }
    }

    internal class ForegroundTracker(
        private val onForeground: () -> Unit,
        private val onBackground: () -> Unit,
    ) : Application.ActivityLifecycleCallbacks {

        private var startedCount = 0
        private var foregrounded = false

        override fun onActivityStarted(activity: Activity) = activityStarted()

        override fun onActivityStopped(activity: Activity) =
            activityStopped(activity.isChangingConfigurations)

        internal fun activityStarted() {
            startedCount += 1
            if (!foregrounded) {
                foregrounded = true
                onForeground()
            }
        }

        internal fun activityStopped(isChangingConfigurations: Boolean) {
            startedCount = maxOf(0, startedCount - 1)
            if (startedCount == 0 && !isChangingConfigurations && foregrounded) {
                foregrounded = false
                onBackground()
            }
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityResumed(activity: Activity) = Unit
        override fun onActivityPaused(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }
}
