package com.flowbiz.onsite

import android.app.Activity
import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.util.Log
import java.util.concurrent.Executors

/**
 * Public entry point (SPEC §2) — a thin static facade over one
 * [FlowbizCore] instance created at [initialize].
 *
 * SPEC §3 invariants enforced here:
 * - **Never throws**: every entry wraps its work in a catch-all.
 * - Reference parameters are declared **nullable** on purpose: Java host
 *   apps have no compile-time null checking, and a non-null Kotlin
 *   signature would make the compiler emit an
 *   `Intrinsics.checkNotNullParameter` preamble that throws before the
 *   catch-all is entered. A null argument is a no-op with a debug warning
 *   instead. Kotlin callers are unaffected (non-null arguments flow
 *   through seamlessly).
 * - Any call before [initialize] is a no-op with a debug warning.
 * - Double [initialize] is a no-op; the first config wins.
 * - Every API is callable from any thread; work is handed to the SDK's
 *   single background scheduler and the caller returns immediately.
 *
 * The facade stays deliberately thin — the behavioral tests live on
 * [FlowbizCore] (constructed with fakes); the facade's no-op paths
 * (pre-init, null arguments) are unit-tested (including from Java source,
 * see `FlowbizJavaNullSafetyTest`), while its production wiring
 * (SharedPreferences, queue file, lifecycle callbacks, real clock/network)
 * is exercised by the demo app (SPEC §14).
 */
object Flowbiz {

    private const val LOG_TAG = "FlowbizOnsite"

    @Volatile
    private var core: FlowbizCore? = null

    /**
     * Initializes the SDK. Call once, e.g. from `Application.onCreate`
     * (which runs before any activity — the heartbeat then starts on the
     * first activity start; initializing later, with an activity already
     * started, delays foreground detection to the next start/stop edge).
     *
     * A blank [FlowbizConfig.appId] makes this a complete no-op (SPEC §2);
     * other invalid config values are replaced/clamped with debug warnings.
     * A null [context] or [config] (possible from Java callers) is a no-op
     * with a debug warning — never an NPE (SPEC §3).
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

    /**
     * Tracks a typed event (SPEC §5). Enqueues and returns immediately.
     * A null [event] (possible from Java callers) is a no-op with a debug
     * warning — never an NPE (SPEC §3).
     */
    @JvmStatic
    fun track(event: Event?) {
        if (event == null) {
            SdkLog.debug("Flowbiz.track ignored: null event")
            return
        }
        withCore("track") { it.track(event) }
    }

    /** Clears user identity, rotates the session (SPEC §6). */
    @JvmStatic
    fun logout() = withCore("logout") { it.logout() }

    /** Opt-out switch (SPEC §12); persisted across launches. */
    @JvmStatic
    fun setEnabled(enabled: Boolean) = withCore("setEnabled") { it.setEnabled(enabled) }

    /** Forces a queue flush (SPEC §2). Fire-and-forget. */
    @JvmStatic
    fun flush() = withCore("flush") { it.flush() }

    /**
     * SPEC §10.1 token relay: persists the token and emits
     * `push.token.sync` through the normal pipeline. Requires [initialize];
     * a null/blank token is a no-op with a debug warning.
     */
    @JvmStatic
    fun setPushToken(token: String?) {
        if (token.isNullOrBlank()) {
            SdkLog.debug("Flowbiz.setPushToken ignored: null/blank token")
            return
        }
        withCore("setPushToken") { it.setPushToken(token) }
    }

    /**
     * SPEC §10.1: emits `push.token.remove` with the stored token and
     * forgets it. No stored token → no-op. Requires [initialize].
     */
    @JvmStatic
    fun removePushToken() = withCore("removePushToken") { it.removePushToken() }

    /**
     * SPEC §10.3: parses a push payload carrying the `"flowbiz"` marker key
     * (a JSON-encoded string, SPEC §10.2). Returns null when the payload is
     * not ours (marker absent or undecodable).
     *
     * Pure, synchronous, never throws; callable before [initialize]
     * (SPEC §3) and from any thread — typically the app's
     * `FirebaseMessagingService.onMessageReceived` (`message.data`) or the
     * launch intent extras on notification tap.
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
     * SPEC §11: decodes the `_mb_cr_` query parameter of an incoming deep
     * link into a [RecoveryPayload]. Returns null = no decodable `_mb_cr_`
     * param, missing/invalid `utm_source`, or (once initialized) a tenant
     * mismatch.
     *
     * Pure, synchronous, never throws; callable before [initialize]
     * (SPEC §3). The SDK does not adopt the decoded user as its identity.
     */
    @JvmStatic
    fun handleLink(url: Uri?): RecoveryPayload? = try {
        url?.let { RecoveryLinkParser.parse(it.toString(), core?.config?.appId) }
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
     * Started-activity counting → foreground/background edges (SPEC §1
     * lifecycle source). On a configuration change (rotation) there is
     * **no overlap**: the old activity is stopped and destroyed *before*
     * the replacement is created and started, so the count briefly hits 0
     * while the app stays visually foregrounded. That stop is identified
     * via [Activity.isChangingConfigurations] and the background edge is
     * skipped (a background edge per rotation would reset the heartbeat
     * cadence and spuriously reset the flush backoff); the [foregrounded]
     * flag then keeps the replacement's start from firing a spurious
     * foreground edge. Callbacks arrive on the main thread only, so the
     * state needs no synchronization.
     *
     * Internal (not private) with [Function0] seams instead of a
     * [FlowbizCore], so the counting logic is unit-testable on a plain JVM
     * where no real [Activity] can exist (see [activityStarted] /
     * [activityStopped]).
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
