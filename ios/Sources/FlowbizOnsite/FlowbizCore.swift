import Foundation

/// Every entry point hops onto the serial `scheduler` and returns at once;
/// the pipeline state (`lastPage`, `foregrounded`, `utmContext`) is confined
/// to it. A failing step drops its event with a debug log. The queue is built
/// on first use: its init reads the file, which must stay off the caller's
/// thread at initialize.
final class FlowbizCore: @unchecked Sendable {

    static let platform = "ios"

    let config: FlowbizConfig
    private let identityStore: IdentityStore
    private let sessionManager: SessionManager
    private let enabledState: EnabledState
    private let pushTokenStore: PushTokenStore
    private let dedupStore: DedupStore
    private let utmStore: UtmStore
    private let sender: any HttpSender
    private let scheduler: any TaskScheduler
    private let clock: any Clock
    private let deviceContext: DeviceContext
    private let reachability: any ReachabilityMonitor
    private let heartbeatIntervalMillis: Int64

    private let queueFactory: () -> EventQueue
    private let transportLock = NSLock()
    private var lazyQueue: EventQueue?
    private var lazyFlushController: FlushController?

    private lazy var heartbeat = HeartbeatScheduler(scheduler: scheduler, sender: sender) { [weak self] in
        self?.buildPingEntry()
    }

    /// Feeds `context.url` and the ping `page`; set by every `pageView` with a
    /// path or title, even a suppressed duplicate (the user *is* on that screen).
    struct PageState { let title: String?; let url: String? }
    private var lastPage: PageState?

    private var foregrounded = false

    /// `context.utm` of every envelope built from now on; nil omits it.
    private var utmContext: String?

    init(
        config: FlowbizConfig,
        store: any KeyValueStore,
        queueFactory: @escaping () -> EventQueue,
        sender: any HttpSender,
        scheduler: any TaskScheduler,
        clock: any Clock,
        deviceContext: DeviceContext,
        reachability: any ReachabilityMonitor
    ) {
        self.config = config
        self.identityStore = IdentityStore(store: store)
        self.sessionManager = SessionManager(store: store, clock: clock)
        self.enabledState = EnabledState(store: store)
        self.pushTokenStore = PushTokenStore(store: store)
        self.dedupStore = DedupStore(store: store, clock: clock)
        self.utmStore = UtmStore(store: store, clock: clock)
        self.queueFactory = queueFactory
        self.sender = sender
        self.scheduler = scheduler
        self.clock = clock
        self.deviceContext = deviceContext
        self.reachability = reachability
        self.heartbeatIntervalMillis = Int64(config.heartbeatInterval * 1000)

        reachability.start { [weak self] in
            guard let self, self.enabledState.isEnabled else { return }
            self.flushController.requestFlush(.networkRestored)
        }

        // A process start may be a push or background wake, not a visit:
        // load the stored UTMs without sliding their expiry.
        submit { core in core.refreshUtm(link: nil, slideExpiry: false) }
    }

    // MARK: - Facade entry points (any thread, return immediately, never throw)

    func track(_ event: Event) {
        submit { core in
            guard core.enabledState.isEnabled else {
                SdkLog.debug("track dropped: SDK disabled")
                return
            }
            // Before the envelope is built, so the login event itself carries user_id.
            switch event {
            case .accountLogin(let user), .accountSync(let user):
                core.identityStore.setUser(userId: user.userId, email: user.email)
            default:
                break
            }
            core.sessionManager.touch()
            let session = core.sessionManager.currentSession()
            do {
                let wireName = EventSerializer.wireName(event)
                let dataJSON = try EventSerializer.dataJSONString(event, baseUri: core.config.baseUriOrNil)
                if case .pageView(let path, let title) = event, path != nil || title != nil {
                    core.lastPage = PageState(title: title, url: UrlResolver.resolve(path, baseUri: core.config.baseUriOrNil))
                }
                if core.dedupStore.shouldSuppress(wireName: wireName, dataJSON: dataJSON) {
                    SdkLog.debug("event suppressed: duplicate \(wireName) within dedup window")
                    return
                }
                let now = core.clock.wallMillis()
                let entry = try EnvelopeBuilder.build(
                    event: event,
                    hash: UUID().uuidString.lowercased(),
                    createdAtMillis: now,
                    sentAtMillis: now,
                    timezone: Self.formatTimezoneOffset(minutes: core.deviceContext.timezoneOffsetMinutes(now)),
                    userId: core.identityStore.userId,
                    anonymousId: core.identityStore.anonymousId,
                    sessionId: session.sessionId,
                    visitCount: session.visitCount,
                    language: core.deviceContext.language,
                    screen: core.deviceContext.screen(),
                    appId: core.config.appId,
                    platform: Self.platform,
                    sdkVersion: SDKVersion.current,
                    contextUrl: core.lastPage?.url,
                    baseUri: core.config.baseUriOrNil,
                    recoveryUrl: core.config.recoveryUrl,
                    utm: core.utmContext
                )
                core.queue.append(try CanonicalJSON.render(entry))
                core.flushController.requestFlush(.eventTracked)
            } catch {
                SdkLog.debug("event dropped: serialization failed")
            }
        }
    }

    /// Queued like `track`, so a `track` issued afterwards from the same
    /// thread carries the link's UTMs.
    func captureUtm(fromLink link: String) {
        submit { core in core.refreshUtm(link: link, slideExpiry: true) }
    }

    /// `push.token.remove` goes out before the identity is cleared so it
    /// carries the outgoing `user_id`: the backend must know whose token to
    /// drop. Local state is cleared even while disabled; captured UTMs are
    /// kept, as on web.
    func logout() {
        submit { core in
            if let token = core.pushTokenStore.token {
                core.emitTokenRemoval(token)
            }
            core.identityStore.clearUser()
            core.sessionManager.rotate()
            core.pushTokenStore.clear()
            SdkLog.debug("logout: user cleared, session rotated, push token cleared")
        }
    }

    /// Persisted even while disabled (the event is dropped), so a later
    /// enable and logout can remove the token actually registered with APNs.
    func setPushToken(_ token: String) {
        submit { core in
            core.pushTokenStore.set(token)
            core.emitInternal(wireName: "push.token.sync", dataJSON: Self.tokenDataJSON(token))
        }
    }

    /// While disabled the event is dropped but the token still cleared.
    func removePushToken() {
        submit { core in
            guard let token = core.pushTokenStore.token else {
                SdkLog.debug("removePushToken ignored: no token stored")
                return
            }
            core.emitTokenRemoval(token)
            core.pushTokenStore.clear()
        }
    }

    func setEnabled(_ enabled: Bool) {
        submit { core in
            let wasEnabled = core.enabledState.isEnabled
            core.enabledState.setEnabled(enabled)
            if !enabled {
                // Idempotent: stopping an already-stopped heartbeat is
                // harmless, so a repeated disable needs no guard.
                core.heartbeat.stop()
                SdkLog.debug("SDK disabled: heartbeat stopped, events dropped, network gated")
            } else if !wasEnabled {
                if core.foregrounded {
                    core.heartbeat.start(intervalMillis: core.heartbeatIntervalMillis)
                }
                // A token set while disabled was stored but never synced;
                // dedup still skips one synced < 20 min ago.
                if let token = core.pushTokenStore.token {
                    core.emitInternal(wireName: "push.token.sync", dataJSON: Self.tokenDataJSON(token))
                }
                core.flushController.requestFlush(.explicit)
                SdkLog.debug("SDK re-enabled")
            }
        }
    }

    func flush() {
        submit { core in
            guard core.enabledState.isEnabled else {
                SdkLog.debug("flush ignored: SDK disabled")
                return
            }
            core.flushController.requestFlush(.explicit)
        }
    }

    // MARK: - Lifecycle (wired by the facade's UIApplication observers)

    /// App entered foreground. Idempotent — a redundant call (already
    /// foregrounded, e.g. `didBecomeActive` after the initialize-time state
    /// probe) is ignored so heartbeat cadence isn't reset.
    func onForeground() {
        submit { core in
            guard !core.foregrounded else { return }
            core.foregrounded = true
            core.sessionManager.onForeground()
            core.refreshUtm(link: nil, slideExpiry: true) // before the first ping
            if core.enabledState.isEnabled {
                core.heartbeat.start(intervalMillis: core.heartbeatIntervalMillis)
                core.flushController.requestFlush(.appForeground)
            }
        }
    }

    func onBackground() {
        submit { core in
            core.foregrounded = false
            core.heartbeat.stop()
        }
    }

    // MARK: - Heartbeat

    /// A ping counts as session activity and, like web pings, describes the
    /// current page.
    private func buildPingEntry() -> String? {
        guard enabledState.isEnabled else { return nil }
        sessionManager.touch()
        let session = sessionManager.currentSession()
        let now = clock.wallMillis()
        let entry = EnvelopeBuilder.buildPing(
            hash: UUID().uuidString.lowercased(),
            createdAtMillis: now,
            sentAtMillis: now,
            timezone: Self.formatTimezoneOffset(minutes: deviceContext.timezoneOffsetMinutes(now)),
            userId: identityStore.userId,
            anonymousId: identityStore.anonymousId,
            sessionId: session.sessionId,
            visitCount: session.visitCount,
            language: deviceContext.language,
            screen: deviceContext.screen(),
            appId: config.appId,
            platform: Self.platform,
            sdkVersion: SDKVersion.current,
            contextUrl: lastPage?.url,
            baseUri: config.baseUriOrNil,
            recoveryUrl: config.recoveryUrl,
            utm: utmContext,
            dataJSON: pingDataJSON()
        )
        return try? CanonicalJSON.render(entry)
    }

    private func pingDataJSON() -> String {
        guard let page = lastPage else { return "{}" }
        var object = [String: Any]()
        if let title = page.title { object["title"] = title }
        if let url = page.url { object["url"] = url }
        return (try? CanonicalJSON.render(["page": object])) ?? "{}"
    }

    // MARK: - Internal raw events

    /// Sorted keys, byte-identical to the Kotlin SDK's rendering.
    private static func tokenDataJSON(_ token: String) -> String {
        (try? CanonicalJSON.render(["token": token, "platform": platform])) ?? "{}"
    }

    /// Clears the `push.token.sync` dedup anchor even when the removal is
    /// dropped: re-registering the same token must sync again.
    private func emitTokenRemoval(_ token: String) {
        emitInternal(wireName: "push.token.remove", dataJSON: Self.tokenDataJSON(token))
        dedupStore.clear(wireName: "push.token.sync")
    }

    /// `track`'s pipeline for wire names outside `Event`.
    private func emitInternal(wireName: String, dataJSON: String) {
        guard enabledState.isEnabled else {
            SdkLog.debug("\(wireName) dropped: SDK disabled")
            return
        }
        sessionManager.touch()
        let session = sessionManager.currentSession()
        do {
            if dedupStore.shouldSuppress(wireName: wireName, dataJSON: dataJSON) {
                SdkLog.debug("event suppressed: duplicate \(wireName) within dedup window")
                return
            }
            let now = clock.wallMillis()
            let entry = EnvelopeBuilder.buildRaw(
                wireName: wireName,
                dataJSON: dataJSON,
                hash: UUID().uuidString.lowercased(),
                createdAtMillis: now,
                sentAtMillis: now,
                timezone: Self.formatTimezoneOffset(minutes: deviceContext.timezoneOffsetMinutes(now)),
                userId: identityStore.userId,
                anonymousId: identityStore.anonymousId,
                sessionId: session.sessionId,
                visitCount: session.visitCount,
                language: deviceContext.language,
                screen: deviceContext.screen(),
                appId: config.appId,
                platform: Self.platform,
                sdkVersion: SDKVersion.current,
                contextUrl: lastPage?.url,
                baseUri: config.baseUriOrNil,
                recoveryUrl: config.recoveryUrl,
                utm: utmContext
            )
            queue.append(try CanonicalJSON.render(entry))
            flushController.requestFlush(.eventTracked)
        } catch {
            SdkLog.debug("\(wireName) dropped: serialization failed")
        }
    }

    // MARK: - UTM attribution

    /// Web `setUtmNavigationContext`: the link's UTMs merged over the stored
    /// set become `context.utm`; every visit (a link, a foreground) slides
    /// the expiry.
    private func refreshUtm(link: String?, slideExpiry: Bool) {
        let stored = utmStore.load()
        let current = link.map(UtmLinkParser.extract) ?? []
        let merged = UtmLinkParser.merge(stored: stored, current: current)
        guard !merged.isEmpty else {
            utmContext = nil
            return
        }
        do {
            if slideExpiry { try utmStore.save(merged) }
            utmContext = CanonicalJSON.renderStringPairs(merged)
            SdkLog.debug("utm context: \(current.count) captured, \(merged.count) active")
        } catch {
            SdkLog.debug("utm refresh failed: \(type(of: error))")
        }
    }

    // MARK: - Plumbing

    private func submit(_ task: @escaping @Sendable (FlowbizCore) -> Void) {
        scheduler.execute { [weak self] in
            guard let self else { return }
            task(self)
        }
    }

    private var queue: EventQueue {
        transportLock.lock()
        defer { transportLock.unlock() }
        if let queue = lazyQueue { return queue }
        let queue = queueFactory()
        lazyQueue = queue
        return queue
    }

    private var flushController: FlushController {
        transportLock.lock()
        if let controller = lazyFlushController {
            transportLock.unlock()
            return controller
        }
        transportLock.unlock()
        let queue = self.queue // build outside the lock to avoid recursion
        transportLock.lock()
        defer { transportLock.unlock() }
        if let controller = lazyFlushController { return controller }
        let enabledState = self.enabledState
        let controller = FlushController(
            queue: queue,
            sender: sender,
            scheduler: scheduler,
            clock: clock,
            isActive: { enabledState.isEnabled }
        )
        lazyFlushController = controller
        return controller
    }

    /// From minutes, not hours: zones like +05:30 and +05:45 exist.
    static func formatTimezoneOffset(minutes: Int) -> String {
        let sign = minutes < 0 ? "-" : "+"
        let absMinutes = abs(minutes)
        return String(format: "%@%02d:%02d", sign, absMinutes / 60, absMinutes % 60)
    }
}
