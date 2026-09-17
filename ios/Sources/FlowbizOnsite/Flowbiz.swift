import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

/// Public entry point (SPEC §2) — a thin static facade (namespace enum)
/// over one `FlowbizCore` instance created at `initialize`.
///
/// SPEC §3 invariants enforced here:
/// - **Never throws**: no public entry is throwing; internal failures
///   degrade to debug logs.
/// - Any call before `initialize` is a no-op with a debug warning.
/// - Double `initialize` is a no-op; the first config wins.
/// - Every API is callable from any thread; work is handed to the SDK's
///   serial background queue and the caller returns immediately.
///
/// The facade is deliberately too thin to need its own test suite — the
/// behavioral tests live on `FlowbizCore` (constructed with fakes); the
/// facade's production wiring (UserDefaults suite, queue file, UIKit
/// lifecycle notifications, real clock/network) is exercised by the demo
/// app (SPEC §14).
public enum Flowbiz {

    /// Lock-guarded singleton state (strict-concurrency-clean shared
    /// mutable state). Also retains the NotificationCenter observer tokens
    /// for the SDK's lifetime.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var core: FlowbizCore?
        private var observers: [NSObjectProtocol] = []

        var currentCore: FlowbizCore? {
            lock.lock()
            defer { lock.unlock() }
            return core
        }

        /// Constructs and installs the core under the lock when none is
        /// set; returns nil when already initialized (first config wins,
        /// SPEC §3). Construction happens *after* winning the install slot
        /// so a losing concurrent `initialize` never builds a core — the
        /// core's init starts reachability monitoring, and a discarded
        /// loser must not leave a started `NWPathMonitor` behind. The
        /// factory is cheap and non-blocking (all component inits are
        /// in-memory; queue-file I/O is deferred to first use), so holding
        /// the lock across it is safe.
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

    /// Lock-guarded holder mirroring `SdkLog`'s `SinkBox` (warning-clean
    /// under strict concurrency) for the testable `debugSink` seam below.
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

    /// Testable seam for the sink installed when `debug` is enabled.
    /// Production default writes through `os_log`; tests substitute a
    /// capture so `ConfigSanitizer` warnings (I1: emitted during
    /// `initialize`, before any test could otherwise observe them) can be
    /// asserted without reading the system log.
    static var debugSink: @Sendable (String) -> Void {
        get { debugSinkBox.current }
        set { debugSinkBox.current = newValue }
    }

    /// Initializes the SDK. Call once, ideally from
    /// `application(_:didFinishLaunchingWithOptions:)` on the main thread.
    /// Initializing while the app is already foregrounded is handled: the
    /// current application state is probed on the main actor and the
    /// heartbeat starts immediately when the app is active.
    ///
    /// A blank `appId` makes this a complete no-op (SPEC §2); other invalid
    /// config values are replaced/clamped with debug warnings.
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
        // The core is constructed inside the install lock: a concurrent
        // initialize that loses the race must return before building a
        // core at all (its init starts reachability monitoring). The debug
        // log sink is installed inside the same closure — only the *winning*
        // initialize may set it (a losing concurrent call must leave no
        // trace) — and *before* `ConfigSanitizer.sanitize` runs (I1), so its
        // warnings (invalid baseUri/recoveryUrl/collectorUrl, clamped
        // heartbeat) land in the sink instead of being dropped on the first
        // ever `initialize` call. `config.debug` gates this (not
        // `sanitized.debug`, which isn't known yet — sanitize doesn't touch
        // the flag itself, so the raw value is equivalent).
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

    /// Tracks a typed event (SPEC §5). Enqueues and returns immediately.
    public static func track(_ event: Event) {
        withCore("track") { $0.track(event) }
    }

    /// Clears user identity, rotates the session (SPEC §6).
    public static func logout() {
        withCore("logout") { $0.logout() }
    }

    /// Opt-out switch (SPEC §12); persisted across launches.
    public static func setEnabled(_ enabled: Bool) {
        withCore("setEnabled") { $0.setEnabled(enabled) }
    }

    /// Forces a queue flush (SPEC §2). Fire-and-forget.
    public static func flush() {
        withCore("flush") { $0.flush() }
    }

    /// SPEC §10.1 token relay: persists the token and emits
    /// `push.token.sync` through the normal pipeline. Requires
    /// `initialize`; a blank token is a no-op with a debug warning.
    public static func setPushToken(_ token: String) {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            SdkLog.debug("Flowbiz.setPushToken ignored: blank token")
            return
        }
        withCore("setPushToken") { $0.setPushToken(token) }
    }

    /// SPEC §10.1: emits `push.token.remove` with the stored token and
    /// forgets it. No stored token → no-op. Requires `initialize`.
    public static func removePushToken() {
        withCore("removePushToken") { $0.removePushToken() }
    }

    /// SPEC §10.3: parses a push payload carrying the `"flowbiz"` marker
    /// key — per contract a JSON-encoded string (SPEC §10.2); a nested
    /// dictionary (possible in APNs userInfo) is tolerated leniently.
    /// Returns nil when the payload is not ours (marker absent or
    /// undecodable).
    ///
    /// Pure, synchronous, never throws; callable before `initialize`
    /// (SPEC §3) and from any thread — typically from the
    /// `UNUserNotificationCenter` delegate (`userInfo`) both on foreground
    /// receipt and notification tap.
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

    /// SPEC §11: decodes the `_mb_cr_` query parameter of an incoming
    /// deep link (Universal Link entry point) into a `RecoveryPayload`.
    /// Returns null = no decodable `_mb_cr_` param, missing/invalid
    /// `utm_source`, or (once initialized) a tenant mismatch.
    ///
    /// Pure, synchronous, never throws; callable before `initialize`
    /// (SPEC §3). The SDK does not adopt the decoded user as its identity.
    public static func handleLink(_ url: URL?) -> RecoveryPayload? {
        RecoveryLinkParser.parse(url?.absoluteString, expectedAppId: state.currentCore?.config.appId)
    }

    private static func withCore(_ name: String, _ action: (FlowbizCore) -> Void) {
        guard let core = state.currentCore else {
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

    /// Language and timezone come from Foundation (thread-safe); the screen
    /// size must be read on the main actor (`UIScreen`), so it is captured
    /// into a box — synchronously when initialize runs on the main thread
    /// (the documented call site), otherwise via a main-actor hop, during
    /// which the placeholder `0x0` may appear on the first envelopes.
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

    /// SPEC §1 lifecycle source: `UIApplication` notifications.
    /// `didBecomeActive` complements `willEnterForeground` for the cold
    /// launch (no foreground transition happens then); `FlowbizCore`'s
    /// foreground handling is idempotent so overlapping signals are safe.
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
