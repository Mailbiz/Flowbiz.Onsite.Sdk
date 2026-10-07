package br.com.flowbiz.onsite

import org.json.JSONObject
import java.util.UUID

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

    // Lazy: the constructor reads the queue file, which must not happen on the caller's main thread.
    private val queue: EventQueue by lazy(queueFactory)
    private val flushController: FlushController by lazy {
        FlushController(queue, sender, scheduler, clock, isActive = { enabledState.isEnabled })
    }

    private val heartbeat = HeartbeatScheduler(scheduler, sender) { buildPingEntry() }
    private val heartbeatIntervalMillis = config.heartbeatIntervalSeconds * 1000L

    internal data class PageState(val title: String?, val url: String?)
    private var lastPage: PageState? = null

    private var foregrounded = false

    // Declared before init: an inline scheduler runs the startup refresh during construction.
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
        // A process start may be a push or a background job, not a visit: load without sliding the expiry.
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
            // Never for page.view: web pageView() carries no data, so it skips the EventsState dedup.
            if (wireName != "page.view" && dedupStore.shouldSuppress(wireName, dataJson)) {
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

    fun logout() = submit("logout") {
        // Before clearUser: the backend needs the outgoing user_id. UTMs are kept, as on web.
        pushTokenStore.token?.let { token ->
            emitTokenRemoval(token)
        }
        identityStore.clearUser()
        sessionManager.rotate()
        pushTokenStore.clear()
        SdkLog.debug("logout: user cleared, session rotated, push token cleared")
    }

    fun setPushToken(token: String) = submit("setPushToken") {
        // Persisted even while disabled: re-enabling re-syncs it and logout can still remove it.
        pushTokenStore.set(token)
        emitInternal("push.token.sync", tokenDataJson(token))
    }

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
            heartbeat.stop()
            SdkLog.debug("SDK disabled: heartbeat stopped, events dropped, network gated")
        } else if (!wasEnabled) {
            if (foregrounded) heartbeat.start(heartbeatIntervalMillis)
            // A token set while disabled was never synced; dedup skips one synced < 20 min ago.
            pushTokenStore.token?.let { token ->
                emitInternal("push.token.sync", tokenDataJson(token))
            }
            flushController.requestFlush(FlushController.FlushReason.EXPLICIT)
            SdkLog.debug("SDK re-enabled")
        }
    }

    fun captureUtm(link: String) = submit("captureUtm") { refreshUtm(link, slideExpiry = true) }

    fun flush() = submit("flush") {
        if (!enabledState.isEnabled) {
            SdkLog.debug("flush ignored: SDK disabled")
            return@submit
        }
        flushController.requestFlush(FlushController.FlushReason.EXPLICIT)
    }

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

    private fun buildPingEntry(): String? = try {
        if (!enabledState.isEnabled) {
            null
        } else {
            // As on web, a ping counts as session activity.
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

    private fun refreshUtm(link: String?, slideExpiry: Boolean) {
        try {
            val current = link?.let(UtmLinkParser::extract).orEmpty()
            // Web `setUtmNavigationContext`: `{...stored, ...current}`, so stored keys keep their position.
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

    private fun emitTokenRemoval(token: String) {
        emitInternal("push.token.remove", tokenDataJson(token))
        // Even when the removal was dropped: re-registering the same token must sync again.
        dedupStore.clear("push.token.sync")
    }

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

        fun formatTimezoneOffset(offsetMinutes: Int): String {
            val sign = if (offsetMinutes < 0) "-" else "+"
            val abs = kotlin.math.abs(offsetMinutes)
            return String.format(java.util.Locale.ROOT, "%s%02d:%02d", sign, abs / 60, abs % 60)
        }
    }
}
