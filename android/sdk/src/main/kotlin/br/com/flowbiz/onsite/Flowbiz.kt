package br.com.flowbiz.onsite

import android.app.Activity
import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.util.Log
import java.util.concurrent.Executors

/**
 * SDK entry point. Every call is safe from any thread, returns immediately
 * and never throws. Calls before [initialize] are no-ops with a debug
 * warning; the decoders ([handlePush], [handleLink], [handlePushOpened])
 * still decode.
 *
 * Reference parameters are nullable on purpose: for a non-null Kotlin
 * parameter the compiler emits a `checkNotNullParameter` preamble that
 * would throw on a Java null before the catch-all is entered. A null
 * argument is a no-op with a debug warning instead.
 */
object Flowbiz {

    private const val LOG_TAG = "FlowbizOnsite"

    @Volatile
    private var core: FlowbizCore? = null

    /**
     * Initializes the SDK. Call once, ideally from `Application.onCreate`:
     * initializing with an activity already started delays foreground
     * detection to the next activity start/stop. Later calls are ignored
     * (the first config wins); a blank [FlowbizConfig.appId] makes this a
     * complete no-op.
     */
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

    /** Tracks [event]: it is queued durably and sent in the background. */
    @JvmStatic
    fun track(event: Event?) {
        if (event == null) {
            SdkLog.debug("Flowbiz.track ignored: null event")
            return
        }
        withCore("track") { it.track(event) }
    }

    /**
     * Signs the user out: clears the user identity and starts a new session.
     * A registered push token is removed first (`push.token.remove`).
     */
    @JvmStatic
    fun logout() = withCore("logout") { it.logout() }

    /**
     * Opt-out switch, persisted across launches. While disabled the SDK drops
     * new events, stops the heartbeat and makes no network calls.
     */
    @JvmStatic
    fun setEnabled(enabled: Boolean) = withCore("setEnabled") { it.setEnabled(enabled) }

    /** Sends the queued events now instead of waiting for the next trigger. */
    @JvmStatic
    fun flush() = withCore("flush") { it.flush() }

    /**
     * Relays the device push token (emits `push.token.sync`) and remembers it
     * so [logout] can remove it. A null/blank token is ignored.
     */
    @JvmStatic
    fun setPushToken(token: String?) {
        if (token.isNullOrBlank()) {
            SdkLog.debug("Flowbiz.setPushToken ignored: null/blank token")
            return
        }
        withCore("setPushToken") { it.setPushToken(token) }
    }

    /** Emits `push.token.remove` for the stored token and forgets it; no-op when none is stored. */
    @JvmStatic
    fun removePushToken() = withCore("removePushToken") { it.removePushToken() }

    /**
     * Decodes a Flowbiz push (the `"flowbiz"` key of FCM `message.data` or of
     * the notification-tap intent extras); null when the push is not ours.
     * Pure and callable before [initialize]. Receiving is not opening, so it
     * captures no UTMs: on tap, call [handlePushOpened].
     */
    @JvmStatic
    fun handlePush(payload: Map<String, String>?): FlowbizPush? = try {
        // The value read is checkcast-guarded: a Java caller can smuggle a
        // non-String value through the erased map — that lands here as a
        // ClassCastException and degrades to null (not ours).
        payload?.get(PushPayloadParser.MARKER_KEY)?.let(PushPayloadParser::parse)
    } catch (t: Throwable) {
        null
    }

    /**
     * Decodes the `_mb_cr_` cart-recovery parameter of an incoming deep link.
     * Null when it is absent or undecodable, `utm_source` is not a Flowbiz
     * one, or (once initialized) the link belongs to another appId.
     *
     * Once initialized it also captures the link's campaign UTMs, whatever
     * the decode returns, so forward every incoming link; a [track] issued
     * afterwards from the same thread carries them. The SDK does not adopt
     * the decoded user as its identity.
     */
    @JvmStatic
    fun handleLink(url: Uri?): RecoveryPayload? = try {
        handleLink(url?.toString(), core)
    } catch (t: Throwable) {
        null
    }

    /** [handleLink] over the link string (JVM tests have no real [Uri]); [current] is null before init. */
    internal fun handleLink(link: String?, current: FlowbizCore?): RecoveryPayload? {
        if (link == null) return null
        current?.captureUtm(link)
        return RecoveryLinkParser.parse(link, current?.config?.appId)
    }

    /**
     * The user tapped this push: [handleLink] over its raw `deep_link`, with
     * the same result; null also for a null push or one without `deep_link`.
     */
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

    /**
     * Started-activity counting → foreground/background edges. On a
     * configuration change the old activity stops *before* its replacement
     * starts, so the count briefly hits 0: that stop
     * ([Activity.isChangingConfigurations]) fires no background edge, which
     * would reset the heartbeat cadence and the flush backoff on every
     * rotation. Callbacks arrive on the main thread only, so the state needs
     * no synchronization.
     */
    internal class ForegroundTracker(
        private val onForeground: () -> Unit,
        private val onBackground: () -> Unit,
    ) : Application.ActivityLifecycleCallbacks {

        private var startedCount = 0
        private var foregrounded = false

        override fun onActivityStarted(activity: Activity) = activityStarted()

        override fun onActivityStopped(activity: Activity) =
            activityStopped(activity.isChangingConfigurations)

        /** Seam for JVM unit tests; production entry is [onActivityStarted]. */
        internal fun activityStarted() {
            startedCount += 1
            if (!foregrounded) {
                foregrounded = true
                onForeground()
            }
        }

        /** Seam for JVM unit tests; production entry is [onActivityStopped]. */
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
