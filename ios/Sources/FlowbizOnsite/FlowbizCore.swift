import Foundation

// Pipeline state (lastPage, foregrounded, utmContext) is confined to the serial scheduler.
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
    // Its own serial queue: a blocking POST must not hold the SDK queue, where track() persists the event.
    private let transportScheduler: any TaskScheduler
    private let clock: any Clock
    private let deviceContext: DeviceContext
    private let reachability: any ReachabilityMonitor
    private let heartbeatIntervalMillis: Int64
    private let backgroundTask: BackgroundFlush.Runner?

    // Lazy: EventQueue's init reads the file, which must stay off the caller's thread at initialize.
    private let queueFactory: () -> EventQueue
    private let transportLock = NSLock()
    private var lazyQueue: EventQueue?
    private var lazyFlushController: FlushController?

    private lazy var heartbeat = HeartbeatScheduler(
        scheduler: scheduler, sender: sender, transport: transportScheduler
    ) { [weak self] in
        self?.buildPingEntry()
    }

    struct PageState { let title: String?; let url: String? }
    private var lastPage: PageState?
    private var foregrounded = false
    // After didEnterBackground, not merely before the first foreground: a launch must not wait on the main thread.
    private var backgrounded = false
    private var utmContext: String?

    init(
        config: FlowbizConfig,
        store: any KeyValueStore,
        queueFactory: @escaping () -> EventQueue,
        pushTokenFileURL: @escaping () -> URL,
        sender: any HttpSender,
        scheduler: any TaskScheduler,
        clock: any Clock,
        deviceContext: DeviceContext,
        reachability: any ReachabilityMonitor,
        transportScheduler: (any TaskScheduler)? = nil,
        backgroundTask: BackgroundFlush.Runner? = nil
    ) {
        self.config = config
        self.identityStore = IdentityStore(store: store)
        self.sessionManager = SessionManager(store: store, clock: clock)
        self.enabledState = EnabledState(store: store)
        self.pushTokenStore = PushTokenStore(fileURL: pushTokenFileURL, legacy: store)
        self.dedupStore = DedupStore(store: store, clock: clock)
        self.utmStore = UtmStore(store: store, clock: clock)
        self.queueFactory = queueFactory
        self.sender = sender
        self.scheduler = scheduler
        self.transportScheduler = transportScheduler ?? scheduler
        self.clock = clock
        self.deviceContext = deviceContext
        self.reachability = reachability
        self.heartbeatIntervalMillis = Int64(config.heartbeatInterval * 1000)
        self.backgroundTask = backgroundTask

        reachability.start { [weak self] in
            guard let self, self.enabledState.isEnabled else { return }
            self.flushController.requestFlush(.networkRestored)
        }

        // A process start may be a push or background wake, not a visit: don't slide the UTM expiry.
        submit { core in core.refreshUtm(link: nil, slideExpiry: false) }
    }

    func track(_ tracked: Event) {
        submit { core in
            guard core.enabledState.isEnabled else {
                SdkLog.debug("track dropped: SDK disabled")
                return
            }
            guard let event = UserSanitizer.sanitize(tracked) else {
                SdkLog.debug("account event dropped: no valid user_id or email")
                return
            }
            // Before the envelope is built, so the login event itself carries user_id.
            switch event {
            case .accountLogin(let user), .accountSync(let user):
                if let userId = UserSanitizer.identityUserId(user) {
                    core.identityStore.setUser(userId: userId, email: user.email)
                }
            default:
                break
            }
            // Sent anyway: Cart.Worker still closes the cart, but credits no UTMs to an order without a real id.
            if case .orderComplete(let order) = event, !Self.isRealOrderId(order.orderId) {
                SdkLog.debug("order.complete without a real orderId: its campaign is not credited; track it once the order is confirmed")
            }
            core.sessionManager.touch()
            let session = core.sessionManager.currentSession()
            do {
                let wireName = EventSerializer.wireName(event)
                let dataJSON = try EventSerializer.dataJSONString(event, baseUri: core.config.baseUriOrNil)
                if case .pageView(let path, let title) = event, path != nil || title != nil {
                    core.lastPage = PageState(title: title, url: UrlResolver.resolve(path, baseUri: core.config.baseUriOrNil))
                }
                // Never for page.view: web pageView() carries no data, so it skips the EventsState dedup.
                if wireName != "page.view" && core.dedupStore.shouldSuppress(wireName: wireName, dataJSON: dataJSON) {
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
                core.flushTrackedEvent()
            } catch {
                SdkLog.debug("event dropped: serialization failed")
            }
        }
    }

    func captureUtm(fromLink link: String) {
        submit { core in core.refreshUtm(link: link, slideExpiry: true) }
    }

    func logout() {
        submit { core in
            // Before clearUser: the backend needs the outgoing user_id. UTMs are kept, as on web.
            if let token = core.pushTokenStore.token {
                core.emitTokenRemoval(token)
            }
            core.identityStore.clearUser()
            core.sessionManager.rotate()
            core.pushTokenStore.clear()
            SdkLog.debug("logout: user cleared, session rotated, push token cleared")
        }
    }

    func setPushToken(_ token: String) {
        submit { core in
            // Stored even while disabled, so re-enabling syncs it and logout can still remove it.
            core.pushTokenStore.set(token)
            core.emitInternal(wireName: "push.token.sync", dataJSON: Self.tokenDataJSON(token))
        }
    }

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
                core.heartbeat.stop()
                SdkLog.debug("SDK disabled: heartbeat stopped, events dropped, network gated")
            } else if !wasEnabled {
                if core.foregrounded {
                    core.heartbeat.start(intervalMillis: core.heartbeatIntervalMillis)
                }
                // A token set while disabled was never synced; dedup skips one synced < 20 min ago.
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

    func onForeground() {
        submit { core in
            guard !core.foregrounded else { return }
            core.foregrounded = true
            core.backgrounded = false
            core.sessionManager.onForeground()
            core.refreshUtm(link: nil, slideExpiry: true)
            if core.enabledState.isEnabled {
                core.heartbeat.start(intervalMillis: core.heartbeatIntervalMillis)
                core.flushController.requestFlush(.appForeground)
            }
        }
    }

    /// `flushed` runs when the flush this starts is over, delivered or not; the caller holds a background task for it.
    func onBackground(flushed: (@Sendable () -> Void)? = nil) {
        submit { core in
            core.foregrounded = false
            core.backgrounded = true
            core.heartbeat.stop()
            guard core.enabledState.isEnabled else {
                flushed?()
                return
            }
            // The last cart.sync before the user leaves: without this it waited for the next app open,
            // and a user who never returns was never seen abandoning the cart.
            core.flushController.requestFlush(.appBackground, onDrained: flushed)
        }
    }

    // An event tracked after the app left the foreground (in the host's own didEnterBackground handler, say):
    // the task held for onBackground's flush may be over, and iOS suspends the app within seconds.
    // One attempt, as there: the task ends with the drain, delivered or not.
    private func flushTrackedEvent() {
        guard backgrounded, let backgroundTask else {
            flushController.requestFlush(.eventTracked)
            return
        }
        let controller = flushController
        backgroundTask { finished in controller.requestFlush(.eventTracked, onDrained: finished) }
    }

    private func buildPingEntry() -> String? {
        guard enabledState.isEnabled else { return nil }
        // As on web, a ping counts as session activity and describes the current page.
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

    private static func tokenDataJSON(_ token: String) -> String {
        (try? CanonicalJSON.render(["token": token, "platform": platform])) ?? "{}"
    }

    private func emitTokenRemoval(_ token: String) {
        emitInternal(wireName: "push.token.remove", dataJSON: Self.tokenDataJSON(token))
        // Even when the removal was dropped: re-registering the same token must sync again.
        dedupStore.clear(wireName: "push.token.sync")
    }

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
            flushTrackedEvent()
        } catch {
            SdkLog.debug("\(wireName) dropped: serialization failed")
        }
    }

    // Web setUtmNavigationContext: the link's UTMs merged over the stored set; a visit slides the expiry.
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
            scheduler: transportScheduler,
            clock: clock,
            isActive: { enabledState.isEnabled }
        )
        lazyFlushController = controller
        return controller
    }

    // The backend's OrderUtmAttribution.IsRealOrderId.
    static func isRealOrderId(_ orderId: String?) -> Bool {
        let trimmed = orderId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty && trimmed != "0"
    }

    static func formatTimezoneOffset(minutes: Int) -> String {
        let sign = minutes < 0 ? "-" : "+"
        let absMinutes = abs(minutes)
        return String(format: "%@%02d:%02d", sign, absMinutes / 60, absMinutes % 60)
    }
}
