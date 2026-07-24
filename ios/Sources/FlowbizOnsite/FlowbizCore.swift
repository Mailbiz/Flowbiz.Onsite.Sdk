import Foundation

/// The SDK engine behind the `Flowbiz` facade. One instance is created at
/// `initialize` with production components; tests construct it directly with
/// fakes (store/clock/sender/scheduler/device/reachability) — the facade
/// stays thin and the behavioral suite lives at this level.
///
/// ## Threading
/// Every entry point hops onto the serial `scheduler` and returns
/// immediately (SPEC §3): all pipeline work — session touch, serialization,
/// dedup, queue I/O — is thread-confined to the scheduler queue.
/// `lastScreenName` and `foregrounded` are scheduler-confined state.
///
/// ## Never-throw
/// Each submitted task handles its throwing steps internally (SPEC §3): a
/// failure degrades to a dropped event and a debug log, never a crash. A
/// non-serializable payload (NaN price) is dropped in the same way and does
/// not affect subsequent events.
///
/// ## Lazy transport
/// The `EventQueue` constructor reads the queue file; deferring its
/// creation to first use keeps that I/O off the caller's (typically main)
/// thread at initialize — the first toucher is always a background thread
/// (scheduler task or reachability callback).
final class FlowbizCore: @unchecked Sendable {

    static let platform = "ios"

    private let config: FlowbizConfig
    private let identityStore: IdentityStore
    private let sessionManager: SessionManager
    private let enabledState: EnabledState
    private let pushTokenStore: PushTokenStore
    private let dedupStore: DedupStore
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

    /// Screen name of the last `pageView`-with-screenName — feeds the ping
    /// `page` payload (SPEC §8, web parity). In-memory only by design; also
    /// refreshed by suppressed duplicate pageViews (the user *is* on that
    /// screen). Scheduler-confined.
    private var lastScreenName: String?

    /// Foreground state (drives heartbeat resume on re-enable). Scheduler-confined.
    private var foregrounded = false

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
    }

    // MARK: - Facade entry points (any thread, return immediately, never throw)

    /// SPEC §5/§7 track pipeline; see steps inline.
    func track(_ event: Event) {
        submit { core in
            // 1. Disabled → drop (SPEC §12). Not-initialized is the facade's check.
            guard core.enabledState.isEnabled else {
                SdkLog.debug("track dropped: SDK disabled")
                return
            }
            // 2. Account events store identity (SPEC §5 side effect) — before
            // the envelope is built, so the login event itself carries user_id.
            switch event {
            case .accountLogin(let user), .accountSync(let user):
                core.identityStore.setUser(userId: user.userId, email: user.email)
            default:
                break
            }
            // 3. Every tracked event slides the session window (SPEC §6).
            core.sessionManager.touch()
            let session = core.sessionManager.currentSession()
            do {
                // 4. Serialize; non-finite numbers throw → drop (SPEC §3).
                let wireName = EventSerializer.wireName(event)
                let dataJSON = try EventSerializer.dataJSONString(event)
                if case .pageView(let screenName) = event, let screenName {
                    core.lastScreenName = screenName
                }
                // 5. Dedup (SPEC §7): identical payload within 20 min → suppress.
                if core.dedupStore.shouldSuppress(wireName: wireName, dataJSON: dataJSON) {
                    SdkLog.debug("event suppressed: duplicate \(wireName) within dedup window")
                    return
                }
                // 6. Build the envelope with a fresh hash and wall timestamps.
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
                    sdkVersion: SDKVersion.current
                )
                // 7. Durable queue + immediate flush attempt (SPEC §9).
                core.queue.append(try CanonicalJSON.render(entry))
                core.flushController.requestFlush(.eventTracked)
            } catch {
                SdkLog.debug("event dropped: serialization failed")
            }
        }
    }

    /// SPEC §6/§10.1 logout: emit `push.token.remove` (if a token is
    /// stored), then clear user identity, rotate the session and clear the
    /// token.
    ///
    /// **Order matters (decision, flagged)**: the removal event is emitted
    /// *before* the identity is cleared so it carries the outgoing
    /// `user_id` — the backend needs to know *whose* token to disassociate.
    /// While disabled the event is dropped (SPEC §12) but the local state
    /// is still cleared so identity never outlives a logout.
    func logout() {
        submit { core in
            if let token = core.pushTokenStore.token {
                core.emitInternal(wireName: "push.token.remove", dataJSON: Self.tokenDataJSON(token))
            }
            core.identityStore.clearUser()
            core.sessionManager.rotate()
            core.pushTokenStore.clear()
            SdkLog.debug("logout: user cleared, session rotated, push token cleared")
        }
    }

    /// SPEC §10.1 token relay: persist the token, emit `push.token.sync`
    /// through the normal pipeline (queued, deduped, session-touched).
    ///
    /// While disabled the event is dropped (SPEC §12) but the token is
    /// **still persisted** (decision, flagged): a later enable + logout must
    /// be able to emit a coherent removal for the token that is actually
    /// registered with APNs/FCM.
    func setPushToken(_ token: String) {
        submit { core in
            core.pushTokenStore.set(token)
            core.emitInternal(wireName: "push.token.sync", dataJSON: Self.tokenDataJSON(token))
        }
    }

    /// SPEC §10.1: emit `push.token.remove` with the stored token, then
    /// forget it. No stored token → no-op. While disabled the event is
    /// dropped but the token is still cleared (mirror of `setPushToken`).
    func removePushToken() {
        submit { core in
            guard let token = core.pushTokenStore.token else {
                SdkLog.debug("removePushToken ignored: no token stored")
                return
            }
            core.emitInternal(wireName: "push.token.remove", dataJSON: Self.tokenDataJSON(token))
            core.pushTokenStore.clear()
        }
    }

    /// SPEC §12 opt-out switch; persisted.
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
                core.flushController.requestFlush(.explicit)
                SdkLog.debug("SDK re-enabled")
            }
        }
    }

    /// SPEC §2 explicit flush; fire-and-forget.
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
            if core.enabledState.isEnabled {
                core.heartbeat.start(intervalMillis: core.heartbeatIntervalMillis)
                core.flushController.requestFlush(.appForeground)
            }
        }
    }

    /// App entered background: heartbeat stops (SPEC §8).
    func onBackground() {
        submit { core in
            core.foregrounded = false
            core.heartbeat.stop()
        }
    }

    // MARK: - Heartbeat

    /// Builds one `page.ping` envelope entry (SPEC §8), or nil to skip the
    /// beat while disabled. The ping touches the session — `page.ping`
    /// counts as activity (SPEC §6) — and carries the last-tracked screen as
    /// `page` data (web semantics: pings describe the current page), `{}`
    /// before the first named pageView. Runs on the scheduler queue.
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
            dataJSON: pingDataJSON()
        )
        return try? CanonicalJSON.render(entry)
    }

    private func pingDataJSON() -> String {
        guard let screenName = lastScreenName else { return "{}" }
        let page: [String: Any] = ["title": screenName, "url": "app://\(screenName)"]
        return (try? CanonicalJSON.render(["page": page])) ?? "{}"
    }

    // MARK: - Internal raw events (SPEC §10.1)

    /// `{"platform":"ios","token":"..."}` rendered canonically (sorted keys
    /// — byte-identical to the Kotlin SDK's rendering, dedup-stable).
    private static func tokenDataJSON(_ token: String) -> String {
        // CanonicalJSON only throws for non-finite numbers; unreachable for
        // two strings — the fallback is pure defensiveness.
        (try? CanonicalJSON.render(["token": token, "platform": platform])) ?? "{}"
    }

    /// Sends an internal raw event (a wire name outside the public `Event`
    /// catalog with a pre-rendered `data` string) through the same pipeline
    /// as `track`: enabled gate, session touch, dedup, envelope, durable
    /// queue + flush. Scheduler-confined (called from submitted tasks only).
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
                sdkVersion: SDKVersion.current
            )
            queue.append(try CanonicalJSON.render(entry))
            flushController.requestFlush(.eventTracked)
        } catch {
            SdkLog.debug("\(wireName) dropped: serialization failed")
        }
    }

    // MARK: - Plumbing

    /// Hops onto the serial scheduler; the caller returns immediately
    /// (SPEC §3). Tasks are non-throwing by construction — throwing steps
    /// are handled with do/catch inside each task.
    private func submit(_ task: @escaping @Sendable (FlowbizCore) -> Void) {
        scheduler.execute { [weak self] in
            guard let self else { return }
            task(self)
        }
    }

    /// Lazily-built durable queue (see "Lazy transport" above). Thread-safe.
    private var queue: EventQueue {
        transportLock.lock()
        defer { transportLock.unlock() }
        if let queue = lazyQueue { return queue }
        let queue = queueFactory()
        lazyQueue = queue
        return queue
    }

    /// Lazily-built flush controller over `queue`. Thread-safe.
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

    /// `±HH:MM` UTC offset (SPEC §4 `timings.timezone`) from an offset in
    /// minutes — minute precision covers half-hour (+05:30) and quarter-hour
    /// (+05:45) zones.
    static func formatTimezoneOffset(minutes: Int) -> String {
        let sign = minutes < 0 ? "-" : "+"
        let absMinutes = abs(minutes)
        return String(format: "%@%02d:%02d", sign, absMinutes / 60, absMinutes % 60)
    }
}
