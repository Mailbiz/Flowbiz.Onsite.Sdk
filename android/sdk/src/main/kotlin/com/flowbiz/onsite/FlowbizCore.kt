package com.flowbiz.onsite

import org.json.JSONObject
import java.util.UUID

/**
 * The SDK engine behind the [Flowbiz] facade. One instance is created at
 * `initialize` with production components; tests construct it directly with
 * fakes (store/clock/sender/scheduler/device/reachability) — the facade
 * stays thin and the behavioral suite lives at this level.
 *
 * ## Threading
 * Every entry point hops onto the serial [scheduler] and returns
 * immediately (SPEC §3): all pipeline work — session touch, serialization,
 * dedup, queue I/O — is thread-confined to the scheduler thread.
 * [lastScreenName] and [foregrounded] are scheduler-confined state.
 *
 * ## Never-throw
 * Each submitted task is wrapped in a catch-all (SPEC §3): a failure
 * degrades to a dropped event and a debug log, never a crash. A
 * non-serializable payload (NaN price) is dropped in the same way and does
 * not affect subsequent events.
 *
 * ## Lazy transport
 * The [EventQueue] constructor reads the queue file; deferring its creation
 * to first use keeps that I/O off the caller's (typically main) thread at
 * initialize — the first toucher is always a background thread (scheduler
 * task or reachability callback).
 */
internal class FlowbizCore(
    private val config: FlowbizConfig,
    store: KeyValueStore,
    queueFactory: () -> EventQueue,
    private val sender: HttpSender,
    private val scheduler: TaskScheduler,
    private val clock: Clock,
    private val deviceContext: DeviceContext,
    reachability: ReachabilityMonitor,
) {

    private val identityStore = IdentityStore(store)
    private val sessionManager = SessionManager(store, clock)
    private val enabledState = EnabledState(store)
    private val pushTokenStore = PushTokenStore(store)
    private val dedupStore = DedupStore(store, clock)

    private val queue: EventQueue by lazy(queueFactory)
    private val flushController: FlushController by lazy {
        FlushController(queue, sender, scheduler, clock, isActive = { enabledState.isEnabled })
    }

    private val heartbeat = HeartbeatScheduler(scheduler, sender) { buildPingEntry() }
    private val heartbeatIntervalMillis = config.heartbeatIntervalSeconds * 1000L

    /**
     * Screen name of the last `pageView`-with-screenName — feeds the ping
     * `page` payload (SPEC §8, web parity). In-memory only by design; also
     * refreshed by suppressed duplicate pageViews (the user *is* on that
     * screen). Scheduler-confined.
     */
    private var lastScreenName: String? = null

    /** Foreground state (drives heartbeat resume on re-enable). Scheduler-confined. */
    private var foregrounded = false

    init {
        reachability.start {
            try {
                if (enabledState.isEnabled) {
                    flushController.requestFlush(FlushController.FlushReason.NETWORK_RESTORED)
                }
            } catch (t: Throwable) {
                SdkLog.debug("network-restored flush failed: ${t.javaClass.simpleName}")
            }
        }
    }

    // MARK: facade entry points (any thread, return immediately, never throw)

    /** SPEC §5/§7 track pipeline; see steps inline. */
    fun track(event: Event) = submit("track") {
        // 1. Disabled → drop (SPEC §12). Not-initialized is the facade's check.
        if (!enabledState.isEnabled) {
            SdkLog.debug("track dropped: SDK disabled")
            return@submit
        }
        // 2. Account events store identity (SPEC §5 side effect) — before the
        // envelope is built, so the login event itself carries user_id.
        when (event) {
            is Event.AccountLogin -> identityStore.setUser(event.user.userId, event.user.email)
            is Event.AccountSync -> identityStore.setUser(event.user.userId, event.user.email)
            else -> Unit
        }
        // 3. Every tracked event slides the session window (SPEC §6).
        sessionManager.touch()
        val session = sessionManager.currentSession()
        try {
            // 4. Serialize; non-finite numbers throw → drop (SPEC §3).
            val wireName = EventSerializer.wireName(event)
            val dataJson = EventSerializer.dataJson(event)
            if (event is Event.PageView && event.screenName != null) {
                lastScreenName = event.screenName
            }
            // 5. Dedup (SPEC §7): identical payload within 20 min → suppress.
            if (dedupStore.shouldSuppress(wireName, dataJson)) {
                SdkLog.debug("event suppressed: duplicate $wireName within dedup window")
                return@submit
            }
            // 6. Build the envelope with a fresh hash and wall timestamps.
            val now = clock.wallMillis()
            val entry = EnvelopeBuilder.build(
                event = event,
                hash = UUID.randomUUID().toString(),
                createdAtMillis = now,
                sentAtMillis = now,
                timezone = formatTimezoneOffset(deviceContext.timezoneOffsetMinutes(now)),
                userId = identityStore.userId,
                anonymousId = identityStore.anonymousId,
                sessionId = session.sessionId,
                visitCount = session.visitCount,
                language = deviceContext.language,
                screen = deviceContext.screen,
                appId = config.appId,
                platform = PLATFORM,
                sdkVersion = SdkVersion.CURRENT,
            )
            // 7. Durable queue + immediate flush attempt (SPEC §9).
            queue.append(CanonicalJson.render(entry))
            flushController.requestFlush(FlushController.FlushReason.EVENT_TRACKED)
        } catch (t: Throwable) {
            SdkLog.debug("event dropped: serialization failed (${t.javaClass.simpleName})")
        }
    }

    /** SPEC §6 logout: clear user, rotate session, clear stored push token. */
    fun logout() = submit("logout") {
        identityStore.clearUser()
        sessionManager.rotate()
        // Slice 5: emit `push.token.remove` with the stored token through the
        // normal pipeline BEFORE clearing it here (SPEC §10.1).
        pushTokenStore.clear()
        SdkLog.debug("logout: user cleared, session rotated, push token cleared")
    }

    /** SPEC §12 opt-out switch; persisted. */
    fun setEnabled(enabled: Boolean) = submit("setEnabled") {
        val wasEnabled = enabledState.isEnabled
        enabledState.setEnabled(enabled)
        if (!enabled) {
            // Idempotent: stopping an already-stopped heartbeat is harmless,
            // so a repeated disable needs no guard.
            heartbeat.stop()
            SdkLog.debug("SDK disabled: heartbeat stopped, events dropped, network gated")
        } else if (!wasEnabled) {
            if (foregrounded) heartbeat.start(heartbeatIntervalMillis)
            flushController.requestFlush(FlushController.FlushReason.EXPLICIT)
            SdkLog.debug("SDK re-enabled")
        }
    }

    /** SPEC §2 explicit flush; fire-and-forget. */
    fun flush() = submit("flush") {
        if (!enabledState.isEnabled) {
            SdkLog.debug("flush ignored: SDK disabled")
            return@submit
        }
        flushController.requestFlush(FlushController.FlushReason.EXPLICIT)
    }

    // MARK: lifecycle (wired by the facade's ActivityLifecycleCallbacks)

    /**
     * App entered foreground. Idempotent — a redundant call (already
     * foregrounded) is ignored so heartbeat cadence isn't reset.
     */
    fun onForeground() = submit("onForeground") {
        if (foregrounded) return@submit
        foregrounded = true
        sessionManager.onForeground()
        if (enabledState.isEnabled) {
            heartbeat.start(heartbeatIntervalMillis)
            flushController.requestFlush(FlushController.FlushReason.APP_FOREGROUND)
        }
    }

    /** App entered background: heartbeat stops (SPEC §8). */
    fun onBackground() = submit("onBackground") {
        foregrounded = false
        heartbeat.stop()
    }

    // MARK: heartbeat

    /**
     * Builds one `page.ping` envelope entry (SPEC §8), or null to skip the
     * beat while disabled. The ping touches the session — `page.ping` counts
     * as activity (SPEC §6) — and carries the last-tracked screen as `page`
     * data (web semantics: pings describe the current page), `{}` before the
     * first named pageView. Runs on the scheduler thread.
     */
    private fun buildPingEntry(): String? = try {
        if (!enabledState.isEnabled) {
            null
        } else {
            sessionManager.touch()
            val session = sessionManager.currentSession()
            val now = clock.wallMillis()
            val entry = EnvelopeBuilder.buildPing(
                hash = UUID.randomUUID().toString(),
                createdAtMillis = now,
                sentAtMillis = now,
                timezone = formatTimezoneOffset(deviceContext.timezoneOffsetMinutes(now)),
                userId = identityStore.userId,
                anonymousId = identityStore.anonymousId,
                sessionId = session.sessionId,
                visitCount = session.visitCount,
                language = deviceContext.language,
                screen = deviceContext.screen,
                appId = config.appId,
                platform = PLATFORM,
                sdkVersion = SdkVersion.CURRENT,
                dataJson = pingDataJson(),
            )
            CanonicalJson.render(entry)
        }
    } catch (t: Throwable) {
        SdkLog.debug("ping build failed: ${t.javaClass.simpleName}")
        null
    }

    private fun pingDataJson(): String {
        val screenName = lastScreenName ?: return "{}"
        val page = JSONObject().put("title", screenName).put("url", "app://$screenName")
        return CanonicalJson.render(JSONObject().put("page", page))
    }

    // MARK: plumbing

    /**
     * Hops onto the serial scheduler and applies the SPEC §3 catch-all: the
     * caller returns immediately and no failure ever escapes.
     */
    private fun submit(name: String, task: () -> Unit) {
        try {
            scheduler.execute {
                try {
                    task()
                } catch (t: Throwable) {
                    SdkLog.debug("$name failed: ${t.javaClass.simpleName}")
                }
            }
        } catch (t: Throwable) {
            SdkLog.debug("$name submit failed: ${t.javaClass.simpleName}")
        }
    }

    companion object {
        const val PLATFORM = "android"

        /**
         * `±HH:MM` UTC offset (SPEC §4 `timings.timezone`) from an offset in
         * minutes — minute precision covers half-hour (+05:30) and
         * quarter-hour (+05:45) zones.
         */
        fun formatTimezoneOffset(offsetMinutes: Int): String {
            val sign = if (offsetMinutes < 0) "-" else "+"
            val abs = kotlin.math.abs(offsetMinutes)
            return String.format(java.util.Locale.ROOT, "%s%02d:%02d", sign, abs / 60, abs % 60)
        }
    }
}
