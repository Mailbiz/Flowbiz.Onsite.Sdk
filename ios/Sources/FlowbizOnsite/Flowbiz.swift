import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

/// The SDK entry point. Every call is safe from any thread, returns
/// immediately and never throws. Before `initialize`, calls are no-ops,
/// except that `handlePush`, `handleLink` and `handlePushOpened` still decode.
public enum Flowbiz {

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var core: FlowbizCore?
        private var observers: [NSObjectProtocol] = []

        var currentCore: FlowbizCore? {
            lock.lock()
            defer { lock.unlock() }
            return core
        }

        /// Builds the core only after winning the slot: a losing concurrent
        /// `initialize` must not leave a started `NWPathMonitor` behind. The
        /// factory does no I/O, so holding the lock across it is safe.
        func installIfAbsent(_ makeCore: () -> FlowbizCore) -> FlowbizCore? {
            lock.lock()
            defer { lock.unlock() }
            guard core == nil else { return nil }
            let newCore = makeCore()
            core = newCore
            return newCore
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

    private static let state = State()

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

    /// The `debug` log sink; tests swap it to capture what `initialize` logs.
    static var debugSink: @Sendable (String) -> Void {
        get { debugSinkBox.current }
        set { debugSinkBox.current = newValue }
    }

    /// Starts the SDK. Call once, ideally from
    /// `application(_:didFinishLaunchingWithOptions:)` on the main thread;
    /// later calls are ignored. A blank `appId` makes it a no-op.
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
        // Only the winning initialize may set the sink, and before
        // `sanitize` so its warnings are logged.
        guard let core = state.installIfAbsent({
            if config.debug {
                SdkLog.sink = Flowbiz.debugSink
            }
            let sanitized = ConfigSanitizer.sanitize(config) ?? config
            return FlowbizCore(
                config: sanitized,
                store: UserDefaultsStore(appId: sanitized.appId),
                queueFactory: { EventQueue(fileURL: queueFileURL(appId: sanitized.appId)) },
                sender: URLSessionHttpSender(collectorUrl: sanitized.collectorUrl, platform: FlowbizCore.platform),
                scheduler: DispatchTaskScheduler(queue: serialQueue),
                clock: SystemClock(),
                deviceContext: makeDeviceContext(),
                reachability: PathMonitorReachability(queue: serialQueue)
            )
        }) else {
            // Raced with a concurrent initialize; the winner's config stands.
            SdkLog.debug("initialize ignored: already initialized (first config wins)")
            return
        }
        startLifecycleTracking(core)
        SdkLog.debug("initialized (appId=\(config.appId))")
    }

    /// Queues a typed event for delivery.
    public static func track(_ event: Event) {
        withCore("track") { $0.track(event) }
    }

    /// Unregisters the stored push token, clears the user identity and starts
    /// a new session.
    public static func logout() {
        withCore("logout") { $0.logout() }
    }

    /// Opt-out switch, persisted across launches: while disabled nothing is
    /// tracked or sent.
    public static func setEnabled(_ enabled: Bool) {
        withCore("setEnabled") { $0.setEnabled(enabled) }
    }

    /// Sends queued events now. Fire-and-forget.
    public static func flush() {
        withCore("flush") { $0.flush() }
    }

    /// Registers the device's push token (`push.token.sync`). Requires
    /// `initialize`; a blank token is ignored.
    public static func setPushToken(_ token: String) {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            SdkLog.debug("Flowbiz.setPushToken ignored: blank token")
            return
        }
        withCore("setPushToken") { $0.setPushToken(token) }
    }

    /// Unregisters the stored push token (`push.token.remove`) and forgets
    /// it; a no-op without one. Requires `initialize`.
    public static func removePushToken() {
        withCore("removePushToken") { $0.removePushToken() }
    }

    /// Decodes a Flowbiz push from its `userInfo`, or nil when the push is not
    /// Flowbiz's. Pure; callable before `initialize`. Receiving a push is not
    /// a click, so it captures no UTMs: on tap, also call
    /// `handlePushOpened(push)`.
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

    /// Decodes the cart-recovery payload of an incoming link; nil when it has
    /// none, its `utm_source` is not a Flowbiz one, or (once initialized) it
    /// belongs to another `appId`.
    ///
    /// Once initialized it also captures the link's campaign UTMs, whatever
    /// the decode returns, so forward every incoming link; a `track` issued
    /// afterwards from the same thread carries them.
    @discardableResult
    public static func handleLink(_ url: URL?) -> RecoveryPayload? {
        handleLink(url?.absoluteString, core: currentCore)
    }

    /// The user tapped this push: `handleLink` over its raw `deep_link`
    /// (which the `deepLink` URL may have altered), with the same result;
    /// nil also for a nil push or one without `deep_link`.
    @discardableResult
    public static func handlePushOpened(_ push: FlowbizPush?) -> RecoveryPayload? {
        handleLink(push?.deepLinkString, core: currentCore)
    }

    /// Not `withCore`: without a core the link is still decoded, silently.
    static func handleLink(_ link: String?, core: FlowbizCore?) -> RecoveryPayload? {
        guard let link else { return nil }
        core?.captureUtm(fromLink: link)
        return RecoveryLinkParser.parse(link, expectedAppId: core?.config.appId)
    }

    #if DEBUG
    /// Test seam: a core seen by the public API on the current task only, so
    /// suites running in parallel never see it.
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

    // MARK: - Production wiring

    private static func queueFileURL(appId: String) -> URL {
        EventQueue.defaultFileURL(appId: appId)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("flowbiz_onsite", isDirectory: true)
                .appendingPathComponent(appId, isDirectory: true)
                .appendingPathComponent("queue.jsonl")
    }

    /// `UIScreen` is main-actor only: read synchronously when initialize runs
    /// on the main thread, else after a hop, meanwhile reporting `0x0`.
    private static func makeDeviceContext() -> DeviceContext {
        let language = Locale.preferredLanguages.first ?? "en"
        #if canImport(UIKit)
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
        // Non-UIKit hosts (macOS test runs): no meaningful device screen.
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

    /// Physical pixels; `nativeBounds` is portrait-oriented and
    /// scale-adjusted.
    @MainActor
    private static func currentScreenPixels() -> String {
        let bounds = UIScreen.main.nativeBounds
        return "\(Int(bounds.width))x\(Int(bounds.height))"
    }

    /// `didBecomeActive` covers the cold launch, which has no foreground
    /// transition; `FlowbizCore`'s foreground handling is idempotent, so
    /// overlapping signals are safe.
    private static func startLifecycleTracking(_ core: FlowbizCore) {
        let center = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []
        tokens.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { _ in core.onForeground() })
        tokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in core.onForeground() })
        tokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in core.onBackground() })
        state.retain(observers: tokens)
        // Initialize-while-already-foregrounded: no notification will fire
        // for the current foreground session, so probe the live state once.
        Task { @MainActor in
            if UIApplication.shared.applicationState != .background {
                core.onForeground()
            }
        }
    }
    #else
    /// Non-UIKit hosts (macOS test runs): no lifecycle source — the
    /// heartbeat only runs where UIKit exists.
    private static func startLifecycleTracking(_ core: FlowbizCore) {}
    #endif
}
