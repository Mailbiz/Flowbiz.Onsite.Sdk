import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

/// Every call is thread-safe, returns at once and never throws; before `initialize` only the decoders work.
public enum Flowbiz {

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var core: FlowbizCore?
        private var observers: [NSObjectProtocol] = []
        // Links forwarded before initialize; their UTMs are captured when it runs.
        // Capped: initialize may never succeed, and the newest links win the merge anyway.
        private var pendingLinks: [String] = []
        private static let maxPendingLinks = 20

        var currentCore: FlowbizCore? {
            lock.lock()
            defer { lock.unlock() }
            return core
        }

        func installIfAbsent(_ makeCore: () -> FlowbizCore) -> FlowbizCore? {
            lock.lock()
            defer { lock.unlock() }
            guard core == nil else { return nil }
            // Built under the lock so a losing initialize never starts an NWPathMonitor; it does no I/O.
            let newCore = makeCore()
            core = newCore
            pendingLinks.forEach { newCore.captureUtm(fromLink: $0) }
            pendingLinks.removeAll()
            return newCore
        }

        /// The installed core, or nil after keeping `link` for the coming initialize.
        func coreOrPending(_ link: String) -> FlowbizCore? {
            lock.lock()
            defer { lock.unlock() }
            if core == nil {
                if pendingLinks.count >= Self.maxPendingLinks { pendingLinks.removeFirst() }
                pendingLinks.append(link)
            }
            return core
        }

        var isInitialized: Bool {
            lock.lock()
            defer { lock.unlock() }
            return core != nil
        }

        func retain(observers tokens: [NSObjectProtocol]) {
            lock.lock()
            defer { lock.unlock() }
            observers.append(contentsOf: tokens)
        }
    }

    static let state = State()

    private final class DebugSinkBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: @Sendable (String) -> Void = { message in
            os_log(.debug, log: OSLog(subsystem: "br.com.flowbiz.onsite", category: "FlowbizOnsite"), "%{public}s", message)
        }

        var current: @Sendable (String) -> Void {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                value = newValue
            }
        }
    }

    private static let debugSinkBox = DebugSinkBox()

    static var debugSink: @Sendable (String) -> Void {
        get { debugSinkBox.current }
        set { debugSinkBox.current = newValue }
    }

    /// Call once, from `application(_:didFinishLaunchingWithOptions:)`; later calls are ignored.
    public static func initialize(_ config: FlowbizConfig) {
        guard !state.isInitialized else {
            SdkLog.debug("initialize ignored: already initialized (first config wins)")
            return
        }
        guard !config.appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            SdkLog.debug("FlowbizConfig.appId is blank; initialize is a no-op")
            return
        }
        let serialQueue = DispatchQueue(label: "br.com.flowbiz.onsite")
        // Only the winning initialize sets the sink, before sanitize so its warnings are logged.
        guard let core = state.installIfAbsent({
            if config.debug {
                SdkLog.sink = Flowbiz.debugSink
            }
            let sanitized = ConfigSanitizer.sanitize(config) ?? config
            return FlowbizCore(
                config: sanitized,
                store: UserDefaultsStore(appId: sanitized.appId),
                queueFactory: {
                    EventQueue(fileURL: queueFileURL(appId: sanitized.appId), nowMillis: SystemClock().wallMillis)
                },
                // Beside the queue: that directory is excluded from backups.
                pushTokenFileURL: {
                    queueFileURL(appId: sanitized.appId).deletingLastPathComponent().appendingPathComponent("push_token")
                },
                sender: URLSessionHttpSender(collectorUrl: sanitized.collectorUrl, platform: FlowbizCore.platform),
                scheduler: DispatchTaskScheduler(queue: serialQueue),
                clock: SystemClock(),
                deviceContext: makeDeviceContext(),
                reachability: PathMonitorReachability(queue: serialQueue),
                transportScheduler: DispatchTaskScheduler(queue: DispatchQueue(label: "br.com.flowbiz.onsite.transport")),
                backgroundTask: backgroundTask
            )
        }) else {
            SdkLog.debug("initialize ignored: already initialized (first config wins)")
            return
        }
        startLifecycleTracking(core)
        SdkLog.debug("initialized (appId=\(config.appId))")
    }

    public static func track(_ event: Event) {
        withCore("track") { $0.track(event) }
    }

    /// Clears the user identity, starts a new session and removes the registered push token.
    public static func logout() {
        withCore("logout") { $0.logout() }
    }

    /// Opt-out switch, persisted across launches; while disabled nothing is tracked or sent
    public static func setEnabled(_ enabled: Bool) {
        withCore("setEnabled") { $0.setEnabled(enabled) }
    }

    public static func flush() {
        withCore("flush") { $0.flush() }
    }

    /// Relays the push token; while disabled it is kept and synced on re-enable. `logout` removes it; blank is ignored.
    public static func setPushToken(_ token: String) {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            SdkLog.debug("Flowbiz.setPushToken ignored: blank token")
            return
        }
        withCore("setPushToken") { $0.setPushToken(token) }
    }

    public static func removePushToken() {
        withCore("removePushToken") { $0.removePushToken() }
    }

    /// Decodes a Flowbiz push (nil if not ours); captures no UTMs, so on tap call `handlePushOpened`.
    public static func handlePush(_ payload: [AnyHashable: Any]?) -> FlowbizPush? {
        guard let marker = payload?[PushPayloadParser.markerKey] else { return nil }
        if let string = marker as? String {
            return PushPayloadParser.parse(string)
        }
        if let object = marker as? [String: Any] {
            return PushPayloadParser.parse(object: object)
        }
        return nil
    }

    /// Decodes a cart-recovery link and captures its campaign UTMs; forward every incoming link.
    @discardableResult
    public static func handleLink(_ url: URL?) -> RecoveryPayload? {
        forwardLink(url?.absoluteString)
    }

    /// Call on notification tap: `handleLink` over the push's raw deep link.
    @discardableResult
    public static func handlePushOpened(_ push: FlowbizPush?) -> RecoveryPayload? {
        forwardLink(push?.deepLinkString)
    }

    static func forwardLink(_ link: String?, state: State = Flowbiz.state) -> RecoveryPayload? {
        guard let link else { return nil }
        #if DEBUG
        if let taskCore { return handleLink(link, core: taskCore) }
        #endif
        return handleLink(link, core: state.coreOrPending(link))
    }

    // Not withCore: without a core the link is still decoded.
    static func handleLink(_ link: String?, core: FlowbizCore?) -> RecoveryPayload? {
        guard let link else { return nil }
        core?.captureUtm(fromLink: link)
        return RecoveryLinkParser.parse(link, expectedAppId: core?.config.appId)
    }

    #if DEBUG
    // Task-local so test suites running in parallel never see each other's core.
    @TaskLocal static var taskCore: FlowbizCore?
    #endif

    private static var currentCore: FlowbizCore? {
        #if DEBUG
        if let taskCore { return taskCore }
        #endif
        return state.currentCore
    }

    private static func withCore(_ name: String, _ action: (FlowbizCore) -> Void) {
        guard let core = currentCore else {
            SdkLog.debug("Flowbiz.\(name) ignored: initialize was not called")
            return
        }
        action(core)
    }

    private static func queueFileURL(appId: String) -> URL {
        EventQueue.defaultFileURL(appId: appId)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("flowbiz_onsite", isDirectory: true)
                .appendingPathComponent(appId, isDirectory: true)
                .appendingPathComponent("queue.jsonl")
    }

    private static func makeDeviceContext() -> DeviceContext {
        let language = Locale.preferredLanguages.first ?? "en"
        #if canImport(UIKit)
        // UIScreen is main-actor only: read now on the main thread, else after a hop (0x0 meanwhile).
        let screenBox = ScreenBox()
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                screenBox.value = currentScreenPixels()
            }
        } else {
            Task { @MainActor in
                screenBox.value = currentScreenPixels()
            }
        }
        let screen: @Sendable () -> String = { screenBox.value }
        #else
        let screen: @Sendable () -> String = { "0x0" }
        #endif
        let timezoneOffsetMinutes: @Sendable (Int64) -> Int = { wallMillis in
            let date = Date(timeIntervalSince1970: TimeInterval(wallMillis) / 1000)
            return TimeZone.current.secondsFromGMT(for: date) / 60
        }
        return DeviceContext(
            language: language,
            screen: screen,
            timezoneOffsetMinutes: timezoneOffsetMinutes
        )
    }

    #if canImport(UIKit)
    private final class ScreenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = "0x0"

        var value: String {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                stored = newValue
            }
        }
    }

    @MainActor
    private static func currentScreenPixels() -> String {
        let bounds = UIScreen.main.nativeBounds
        return "\(Int(bounds.width))x\(Int(bounds.height))"
    }

    private static func startLifecycleTracking(_ core: FlowbizCore) {
        let center = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []
        tokens.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { _ in core.onForeground() })
        // Covers the cold launch, which has no foreground transition; onForeground is idempotent.
        tokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in core.onForeground() })
        tokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in
            BackgroundFlush.run(begin: beginBackgroundTask) { finished in core.onBackground(flushed: finished) }
        })
        state.retain(observers: tokens)
        // Initialized while already active: no notification fires for this session, so probe once.
        Task { @MainActor in
            if UIApplication.shared.applicationState != .background {
                core.onForeground()
            }
        }
    }

    // The core asks from its own queue; a background task is begun on the main thread.
    private static let backgroundTask: BackgroundFlush.Runner? = { flush in
        DispatchQueue.main.async { BackgroundFlush.run(begin: beginBackgroundTask, flush: flush) }
    }

    // Called where the notification is posted, the main thread. Nil when iOS grants no background time.
    private static func beginBackgroundTask(_ onExpire: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            let identifier = UIApplication.shared.beginBackgroundTask(withName: "br.com.flowbiz.onsite.flush") {
                onExpire()
            }
            guard identifier != .invalid else { return nil }
            return {
                // Inline on the main thread: the expiration handler must have ended the task when it returns.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(identifier) }
                } else {
                    Task { @MainActor in UIApplication.shared.endBackgroundTask(identifier) }
                }
            }
        }
    }
    #else
    private static let backgroundTask: BackgroundFlush.Runner? = nil
    private static func startLifecycleTracking(_ core: FlowbizCore) {}
    #endif
}
