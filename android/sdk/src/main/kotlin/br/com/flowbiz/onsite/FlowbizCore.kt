package br.com.flowbiz.onsite

import org.json.JSONObject
import java.util.UUID

/**
 * The engine behind [Flowbiz]. Every entry point hops onto the serial
 * [scheduler] and returns immediately; all pipeline state is confined to
 * that thread, and each task runs under a catch-all, so a failure (e.g. a
 * NaN price) drops that event and never crashes.
 *
 * The [EventQueue] is created lazily because its constructor reads the queue
 * file: the first toucher is then a background thread (scheduler task or
 * reachability callback), never the caller's main thread at initialize.
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
     * Last `pageView` with a path or title: feeds `context.url` and the ping
     * `page`. In-memory only; refreshed even by a suppressed duplicate
     * pageView (the user *is* on that screen).
     */
    internal data class PageState(val title: String?, val url: String?)
    private var lastPage: PageState? = null

    /** Drives the heartbeat resume on re-enable. */
    private var foregrounded = false

    // Before `init` on purpose: with an inline scheduler the startup refresh
    // runs during construction, ahead of any initializer declared later.
    private val utmStore = UtmStore(store, clock)

    /** `context.utm` of every entry built from now on; null omits it. */
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
        // A process start may be a push or a background job, not a visit:
        // load without sliding the expiry (a UI launch then foregrounds).
        submit("utmStartup") { refreshUtm(link = null, slideExpiry = false) }
    }

    fun track(event: Event) = submit("track") {
        if (!enabledState.isEnabled) {
            SdkLog.debug("track dropped: SDK disabled")
            return@submit
        }
        // Before the envelope is built, so the login event itself carries user_id.
        when (event) {
            is Event.AccountLogin -> identityStore.setUser(event.user.userId, event.user.email)
            is Event.AccountSync -> identityStore.setUser(event.user.userId, event.user.email)
            else -> Unit
        }
        sessionManager.touch()
        val session = sessionManager.currentSession()
        try {
            val wireName = EventSerializer.wireName(event)
            val dataJson = EventSerializer.dataJson(event, config.baseUriOrNull)
            if (event is Event.PageView && (event.path != null || event.title != null)) {
                lastPage = PageState(event.title, UrlResolver.resolve(event.path, config.baseUriOrNull))
            }
            if (dedupStore.shouldSuppress(wireName, dataJson)) {
                SdkLog.debug("event suppressed: duplicate $wireName within dedup window")
                return@submit
            }
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
            queue.append(CanonicalJson.render(entry))
            flushController.requestFlush(FlushController.FlushReason.EVENT_TRACKED)
        } catch (t: Throwable) {
            SdkLog.debug("event dropped: serialization failed (${t.javaClass.simpleName})")
        }
    }

    /**
     * The removal is emitted *before* the identity is cleared so it carries
     * the outgoing `user_id`: the backend must know whose token to drop.
     * While disabled the event is dropped but the local state is still
     * cleared, so identity never outlives a logout. Captured UTMs are kept,
     * as on web.
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
     * While disabled the sync event is dropped but the token is still
     * persisted: re-enabling re-syncs it, and a logout can still remove the
     * token actually registered with FCM.
     */
    fun setPushToken(token: String) = submit("setPushToken") {
        pushTokenStore.set(token)
        emitInternal("push.token.sync", tokenDataJson(token))
    }

    /** While disabled the event is dropped but the token is still cleared. */
    fun removePushToken() = submit("removePushToken") {
        val token = pushTokenStore.token
        if (token == null) {
            SdkLog.debug("removePushToken ignored: no token stored")
            return@submit
        }
        emitTokenRemoval(token)
        pushTokenStore.clear()
    }

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
            // A token registered while disabled was persisted but its sync
            // was dropped: re-emit it (dedup still skips one synced < 20 min ago).
            pushTokenStore.token?.let { token ->
                emitInternal("push.token.sync", tokenDataJson(token))
            }
            flushController.requestFlush(FlushController.FlushReason.EXPLICIT)
            SdkLog.debug("SDK re-enabled")
        }
    }

    /** Behind [Flowbiz.handleLink]; a `track` submitted afterwards carries the result. */
    fun captureUtm(link: String) = submit("captureUtm") { refreshUtm(link, slideExpiry = true) }

    fun flush() = submit("flush") {
        if (!enabledState.isEnabled) {
            SdkLog.debug("flush ignored: SDK disabled")
            return@submit
        }
        flushController.requestFlush(FlushController.FlushReason.EXPLICIT)
    }

    /**
     * Idempotent, so a redundant call doesn't reset the heartbeat cadence. A
     * real edge is a visit (a web page load): it refreshes the UTMs before the
     * first ping.
     */
    fun onForeground() = submit("onForeground") {
        if (foregrounded) return@submit
        foregrounded = true
        sessionManager.onForeground()
        refreshUtm(link = null, slideExpiry = true)
        if (enabledState.isEnabled) {
            heartbeat.start(heartbeatIntervalMillis)
            flushController.requestFlush(FlushController.FlushReason.APP_FOREGROUND)
        }
    }

    fun onBackground() = submit("onBackground") {
        foregrounded = false
        heartbeat.stop()
    }

    /**
     * One `page.ping` entry, or null to skip the beat while disabled. As on
     * web, a ping counts as session activity and describes the current page
     * (`{}` before the first named pageView).
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

    /**
     * Web `setUtmNavigationContext`: [link]'s UTMs merged over the stored
     * ones become [utmContext]; [slideExpiry] also saves them for another
     * 30 days. A failure keeps the previous context.
     */
    private fun refreshUtm(link: String?, slideExpiry: Boolean) {
        try {
            val current = link?.let(UtmLinkParser::extract).orEmpty()
            // `{...stored, ...current}`: stored keys keep their position.
            val merged = utmStore.load() + current
            if (merged.isEmpty()) {
                utmContext = null
                return
            }
            if (slideExpiry) utmStore.save(merged)
            utmContext = CanonicalJson.renderStringPairs(merged)
            SdkLog.debug("utm context: ${current.size} captured, ${merged.size} active")
        } catch (t: Throwable) {
            SdkLog.debug("utm refresh failed: ${t.javaClass.simpleName}")
        }
    }

    private fun tokenDataJson(token: String): String =
        CanonicalJson.render(JSONObject().put("token", token).put("platform", PLATFORM))

    /**
     * Also clears the `push.token.sync` dedup anchor, even when the removal
     * itself is dropped or suppressed: re-registering the same token within
     * the window must re-sync, as the collector no longer associates it.
     */
    private fun emitTokenRemoval(token: String) {
        emitInternal("push.token.remove", tokenDataJson(token))
        dedupStore.clear("push.token.sync")
    }

    /** The [track] pipeline for a wire event outside the public [Event] catalog. */
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

        /** `±HH:MM` for `timings.timezone`; minute precision covers +05:30 and +05:45 zones. */
        fun formatTimezoneOffset(offsetMinutes: Int): String {
            val sign = if (offsetMinutes < 0) "-" else "+"
            val abs = kotlin.math.abs(offsetMinutes)
            return String.format(java.util.Locale.ROOT, "%s%02d:%02d", sign, abs / 60, abs % 60)
        }
    }
}
