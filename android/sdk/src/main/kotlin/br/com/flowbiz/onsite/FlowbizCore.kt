package br.com.flowbiz.onsite

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
 * dedup, queue I/O, UTM load/evaluation — is thread-confined to the scheduler
 * thread. [lastPage], [foregrounded] and [utmContext] are
 * scheduler-confined state.
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
    internal val config: FlowbizConfig,
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
     * Last page carried by a `pageView` with a path or title — feeds
     * `context.url` on every event and the ping `page` payload (spec §4,
     * §6). In-memory only; refreshed even by suppressed duplicate
     * pageViews (the user *is* on that screen). Scheduler-confined.
     */
    internal data class PageState(val title: String?, val url: String?)
    private var lastPage: PageState? = null

    /** Foreground state (drives heartbeat resume on re-enable). Scheduler-confined. */
    private var foregrounded = false

    /**
     * SPEC §11.1 captured UTMs: [utmStore] persists the merged set with its
     * sliding 30-day expiry; [utmContext] is the rendered `context.utm`
     * string stamped on every entry built (null → key omitted). Set by the
     * read-only loads ([loadUtmContext]: startup, background re-enable) and
     * recomputed at the evaluation points ([evaluateUtm]) — between them the
     * value rides as-is, even past the stored expiry, like the web context
     * that lives for the page's lifetime. Never touched while disabled.
     * Scheduler-confined.
     *
     * Declared **before** the `init` block on purpose: the startup load is
     * submitted from there, and an inline scheduler (tests) runs it during
     * construction — state declared after it would still be uninitialized
     * when the load runs, or re-initialized after it (pinned by
     * `FlowbizCoreUtmTest`).
     */
    private val utmStore = UtmStore(store, clock)
    private var utmContext: String? = null

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
        // SPEC §11.1 item 4 startup load: the stored UTMs ride from the
        // first event, but the expiry does not slide — a process start is
        // not a visit (a push or a background job wakes the app without the
        // user; every UI launch is followed by a real foreground edge, which
        // slides it). Keep this the last initializer of the class (see
        // [utmContext]).
        submit("utmStartup") { loadUtmContext() }
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
            val dataJson = EventSerializer.dataJson(event, config.baseUriOrNull)
            if (event is Event.PageView && (event.path != null || event.title != null)) {
                lastPage = PageState(event.title, UrlResolver.resolve(event.path, config.baseUriOrNull))
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
                contextUrl = lastPage?.url,
                baseUri = config.baseUriOrNull,
                recoveryUrl = config.recoveryUrl,
                utm = utmContext,
            )
            // 7. Durable queue + immediate flush attempt (SPEC §9).
            queue.append(CanonicalJson.render(entry))
            flushController.requestFlush(FlushController.FlushReason.EVENT_TRACKED)
        } catch (t: Throwable) {
            SdkLog.debug("event dropped: serialization failed (${t.javaClass.simpleName})")
        }
    }

    /**
     * SPEC §6/§10.1 logout: emit `push.token.remove` (if a token is stored),
     * then clear user identity, rotate the session and clear the token.
     *
     * **Order matters (decision, flagged)**: the removal event is emitted
     * *before* the identity is cleared so it carries the outgoing `user_id`
     * — the backend needs to know *whose* token to disassociate. While
     * disabled the event is dropped (SPEC §12) but the local state is still
     * cleared so identity never outlives a logout.
     *
     * Captured UTMs are kept (SPEC §11.1 item 6): they describe the traffic
     * source, not the user, and the web never clears them either.
     */
    fun logout() = submit("logout") {
        pushTokenStore.token?.let { token ->
            emitTokenRemoval(token)
        }
        identityStore.clearUser()
        sessionManager.rotate()
        pushTokenStore.clear()
        SdkLog.debug("logout: user cleared, session rotated, push token cleared")
    }

    /**
     * SPEC §10.1 token relay: persist the token, emit `push.token.sync`
     * through the normal pipeline (queued, deduped, session-touched).
     *
     * While disabled the event is dropped (SPEC §12) but the token is
     * **still persisted** (decision, flagged): a later enable + logout must
     * be able to emit a coherent removal for the token that is actually
     * registered with FCM/APNs.
     */
    fun setPushToken(token: String) = submit("setPushToken") {
        pushTokenStore.set(token)
        emitInternal("push.token.sync", tokenDataJson(token))
    }

    /**
     * SPEC §10.1: emit `push.token.remove` with the stored token, then
     * forget it. No stored token → no-op. While disabled the event is
     * dropped but the token is still cleared (mirror of [setPushToken]).
     */
    fun removePushToken() = submit("removePushToken") {
        val token = pushTokenStore.token
        if (token == null) {
            SdkLog.debug("removePushToken ignored: no token stored")
            return@submit
        }
        emitTokenRemoval(token)
        pushTokenStore.clear()
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
            // SPEC §11.1 item 4: nothing was evaluated while disabled —
            // refresh first, so the re-emitted token sync below carries it.
            // A re-enable while foregrounded is an evaluation (slides the
            // expiry); one from the background only loads (not a visit).
            if (foregrounded) evaluateUtm(link = null) else loadUtmContext()
            if (foregrounded) heartbeat.start(heartbeatIntervalMillis)
            // SPEC §10.1/§12: a token registered while disabled was persisted
            // but its sync event was dropped — re-emit for the stored token
            // (normal pipeline, so dedup still applies: a token already
            // synced <20 min ago is not re-sent).
            pushTokenStore.token?.let { token ->
                emitInternal("push.token.sync", tokenDataJson(token))
            }
            flushController.requestFlush(FlushController.FlushReason.EXPLICIT)
            SdkLog.debug("SDK re-enabled")
        }
    }

    /**
     * SPEC §11.1 capture for [Flowbiz.handleLink] (and so for
     * [Flowbiz.handlePushOpened]): evaluates [link]'s UTMs on the scheduler
     * — so a `track` issued afterwards from the same thread carries them —
     * whatever the recovery decode of the link returned.
     */
    fun captureUtm(link: String) = submit("captureUtm") { evaluateUtm(link) }

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
     *
     * A real foreground edge is a SPEC §11.1 evaluation point (the web's
     * per-visit page load): it slides the stored UTMs' expiry — or drops
     * them once expired — before the heartbeat's first ping. While disabled
     * it only removes an expired set.
     */
    fun onForeground() = submit("onForeground") {
        if (foregrounded) return@submit
        foregrounded = true
        sessionManager.onForeground()
        evaluateUtm(link = null)
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
                contextUrl = lastPage?.url,
                baseUri = config.baseUriOrNull,
                recoveryUrl = config.recoveryUrl,
                utm = utmContext,
                dataJson = pingDataJson(),
            )
            CanonicalJson.render(entry)
        }
    } catch (t: Throwable) {
        SdkLog.debug("ping build failed: ${t.javaClass.simpleName}")
        null
    }

    private fun pingDataJson(): String {
        val page = lastPage ?: return "{}"
        val obj = JSONObject()
        if (page.title != null) obj.put("title", page.title)
        if (page.url != null) obj.put("url", page.url)
        return CanonicalJson.render(JSONObject().put("page", obj))
    }

    // MARK: UTM attribution (SPEC §11.1)

    /**
     * One SPEC §11.1 evaluation — the web's `setUtmNavigationContext` on a
     * page load (a visit): merge [link]'s UTMs (none without a link) over
     * the stored set; an empty merge clears [utmContext] and writes nothing,
     * otherwise the set is persisted with a fresh 30-day expiry and rendered
     * as the `context.utm` string. Evaluation points: [captureUtm] (every
     * `handleLink` / `handlePushOpened`), a real foreground edge and a
     * re-enable while foregrounded; startup and a background re-enable only
     * [loadUtmContext].
     *
     * While disabled (SPEC §12) nothing is read, refreshed or surfaced —
     * only an expired set is removed ([UtmStore.purgeIfExpired], which
     * reads the expiry alone). Scheduler-confined; never throws — a failure
     * keeps the previous context. Logs counts only: never the link, a value
     * or the JSON (SPEC §12).
     */
    private fun evaluateUtm(link: String?) {
        try {
            if (!enabledState.isEnabled) {
                if (link != null) SdkLog.debug("utm capture skipped: SDK disabled")
                utmStore.purgeIfExpired()
                return
            }
            val current = link?.let(UtmLinkParser::extract).orEmpty()
            val merged = UtmLinkParser.merge(utmStore.load(), current)
            if (merged.isEmpty()) {
                utmContext = null
                if (link != null) SdkLog.debug("utm capture: no campaign parameters in link")
                return
            }
            utmStore.save(merged)
            utmContext = UtmLinkParser.render(merged)
            SdkLog.debug("utm context set: ${current.size} captured, ${merged.size} active")
        } catch (t: Throwable) {
            SdkLog.debug("utm evaluation failed: ${t.javaClass.simpleName}")
        }
    }

    /**
     * The SPEC §11.1 item 4 read-only load — startup and a re-enable from
     * the background, which are not visits: [utmContext] becomes the stored
     * set (dropped by [UtmStore.load] once expired or corrupt), rendered,
     * or null when there is none. Never writes, so the expiry does not
     * slide.
     *
     * While disabled only an expired set is removed
     * ([UtmStore.purgeIfExpired]) and [utmContext] is left untouched.
     * Scheduler-confined; never throws — a failure keeps the previous
     * context.
     */
    private fun loadUtmContext() {
        try {
            if (!enabledState.isEnabled) {
                utmStore.purgeIfExpired()
                return
            }
            val stored = utmStore.load()
            utmContext = if (stored.isEmpty()) null else UtmLinkParser.render(stored)
        } catch (t: Throwable) {
            SdkLog.debug("utm load failed: ${t.javaClass.simpleName}")
        }
    }

    // MARK: internal raw events (SPEC §10.1)

    private fun tokenDataJson(token: String): String =
        CanonicalJson.render(JSONObject().put("token", token).put("platform", PLATFORM))

    /**
     * Emits `push.token.remove` and clears the `push.token.sync` dedup
     * anchor (SPEC §10.1): after a removal, re-registering the *same* token
     * within the 20-minute window must re-sync — the collector no longer
     * associates it. The anchor is cleared even when the removal event
     * itself is dropped (disabled) or suppressed, mirroring how the token
     * cell is cleared regardless.
     */
    private fun emitTokenRemoval(token: String) {
        emitInternal("push.token.remove", tokenDataJson(token))
        dedupStore.clear("push.token.sync")
    }

    /**
     * Sends an internal raw event (a wire name outside the public [Event]
     * catalog with a pre-rendered `data` string) through the same pipeline
     * as [track]: enabled gate, session touch, dedup, envelope, durable
     * queue + flush. Scheduler-confined (called from submitted tasks only).
     */
    private fun emitInternal(wireName: String, dataJson: String) {
        if (!enabledState.isEnabled) {
            SdkLog.debug("$wireName dropped: SDK disabled")
            return
        }
        sessionManager.touch()
        val session = sessionManager.currentSession()
        try {
            if (dedupStore.shouldSuppress(wireName, dataJson)) {
                SdkLog.debug("event suppressed: duplicate $wireName within dedup window")
                return
            }
            val now = clock.wallMillis()
            val entry = EnvelopeBuilder.buildRaw(
                wireName = wireName,
                dataJson = dataJson,
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
                contextUrl = lastPage?.url,
                baseUri = config.baseUriOrNull,
                recoveryUrl = config.recoveryUrl,
                utm = utmContext,
            )
            queue.append(CanonicalJson.render(entry))
            flushController.requestFlush(FlushController.FlushReason.EVENT_TRACKED)
        } catch (t: Throwable) {
            SdkLog.debug("$wireName dropped: ${t.javaClass.simpleName}")
        }
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
