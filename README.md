# Flowbiz Onsite SDK

Native mobile tracking SDKs for the Flowbiz Onsite platform — a "universal
tracker for native mobile" targeting the existing collector with zero
backend changes. Zero third-party dependencies on both platforms.

Full behavioral specification: [SPEC.md](SPEC.md). Data collection
disclosure (Google Play Data safety mapping): [android/DATA_DISCLOSURE.md](android/DATA_DISCLOSURE.md).
The iOS package bundles a `PrivacyInfo.xcprivacy` privacy manifest.

## Supported versions

| | Android | iOS |
|---|---|---|
| Min OS | Android 8.0 (API 26) | iOS 13 |
| Language | Kotlin | Swift 5.9+ |
| Dependencies | none | none |

## Install

**Android (Maven Central):**

```kotlin
dependencies {
    implementation("com.flowbiz:onsite-sdk:0.1.0")
}
```

**iOS (Swift Package Manager):**

```swift
// Package.swift — or Xcode ▸ Add Package Dependencies with the same URL.
// TODO: repository URL is a placeholder until the public repo location is final.
.package(url: "https://github.com/flowbiz/flowbiz-onsite-sdk.git", from: "0.1.0")
```

Both SDKs version in lockstep; one `vX.Y.Z` tag releases both.

## Quickstart

### Public API surface (complete)

```kotlin
// Android — all entry points @JvmStatic (Java host apps supported)
Flowbiz.initialize(context, FlowbizConfig(appId = "77777", /* optional: */ collectorUrl, debug, heartbeatIntervalSeconds))
Flowbiz.track(event)                    // typed event, see SPEC §5
Flowbiz.logout()                        // clears user identity, rotates session, auto-sends push token removal
Flowbiz.setEnabled(enabled: Boolean)    // opt-out switch, see SPEC §12; persisted; default true
Flowbiz.setPushToken(token: String)
Flowbiz.removePushToken()
Flowbiz.handlePush(payload: Map<String, String>): FlowbizPush?   // null = not ours
Flowbiz.handleLink(url: Uri): RecoveryPayload?                   // null = no mb_recovery param
Flowbiz.flush()                         // force queue flush (optional nicety, fire-and-forget)
```

```swift
// iOS — identical semantics
Flowbiz.initialize(FlowbizConfig(appId: "77777"))
Flowbiz.track(_ event: Event)
Flowbiz.logout()
Flowbiz.setEnabled(_ enabled: Bool)
Flowbiz.setPushToken(_ token: String)
Flowbiz.removePushToken()
Flowbiz.handlePush(_ payload: [AnyHashable: Any]) -> FlowbizPush?
Flowbiz.handleLink(_ url: URL) -> RecoveryPayload?
Flowbiz.flush()
```

There is no callback/handler registration anywhere: the host app receives
deep links and push payloads from the OS, forwards them to the SDK, and
branches on the returned value.

### Android

```kotlin
// Application.onCreate
Flowbiz.initialize(this, FlowbizConfig(appId = "77777"))

// Track typed events (SPEC §5 catalog: PageView, AccountLogin, AccountSync,
// ProductView, CartSync, AddToCart, CartItemUpdate, CartSetPostalCode,
// CartSetCoupon, CheckoutStep, OrderComplete, OrderCancel)
Flowbiz.track(Event.PageView(screenName = "home"))
Flowbiz.track(Event.AccountLogin(User(userId = "u-1", email = "user@example.com")))

// Sign-out: clears identity, rotates session, auto-sends push token removal
Flowbiz.logout()

// Push token relay — from your FirebaseMessagingService
override fun onNewToken(token: String) {
    Flowbiz.setPushToken(token)
}

// Push receipt — from onMessageReceived (and notification-tap intent extras)
val push: FlowbizPush? = Flowbiz.handlePush(message.data)
if (push != null) {
    // push.type, push.title, push.body, push.deepLink, push.data — display/route as you wish
}

// Deep links — from your launcher/deep-link Activity intent
val recovery: RecoveryPayload? = Flowbiz.handleLink(intent.data)
if (recovery != null) {
    // recovery.cartId, recovery.userId, recovery.products[{productId, sku, quantity, recoveryProperties?}]
    // restore the cart however your app does it
}
```

### iOS

```swift
// application(_:didFinishLaunchingWithOptions:)
Flowbiz.initialize(FlowbizConfig(appId: "77777"))

// Track typed events (same catalog as Android)
Flowbiz.track(.pageView(screenName: "home"))
Flowbiz.track(.accountLogin(user: User(userId: "u-1", email: "user@example.com")))

// Sign-out
Flowbiz.logout()

// Push token relay — from didRegisterForRemoteNotificationsWithDeviceToken
Flowbiz.setPushToken(tokenString)

// Push receipt — from your UNUserNotificationCenter delegate (foreground
// receipt and notification tap alike)
if let push = Flowbiz.handlePush(notification.request.content.userInfo) {
    // push.type, push.title, push.body, push.deepLink, push.data
}

// Universal Links — from scene(_:continue:) / onOpenURL
if let recovery = Flowbiz.handleLink(url) {
    // recovery.cartId, recovery.userId, recovery.products — restore the cart
}
```

### Deep-link prerequisite (cart recovery)

Recovery links must point at a domain your app claims via **App Links**
(Android, `assetlinks.json` + auto-verified intent filter) / **Universal
Links** (iOS, `apple-app-site-association` + Associated Domains
entitlement). If the app isn't installed, the same URL falls back to the
existing web recovery flow (SPEC §11).

### Consent / opt-out

`Flowbiz.setEnabled(false)` is the LGPD/GDPR consent hook: persisted across
launches; while disabled the SDK drops new events, stops the heartbeat and
makes no network calls. Re-enabling resumes normal operation and re-syncs a
push token registered while disabled (SPEC §12). The consent UI/decision is
the host app's responsibility — the SDK collects by default until told
otherwise.

## Behavior in one paragraph

`track()` never throws, never blocks, and survives offline: events are
persisted to a disk queue (cap 1000, drop-oldest) and flushed with
exponential backoff on network restore, app foreground, the next track, or
`flush()`. Identical payloads per event type are deduplicated for
20 minutes. A `page.ping` heartbeat (default 60 s, configurable ≥ 15 s)
runs while foregrounded. Sessions rotate after 30 min of inactivity. All
public APIs are callable from any thread, and — with the exception of
`handlePush`/`handleLink`, which are pure parsers that work even before
`initialize` (SPEC §3/§10/§11) — they are no-ops before `initialize`.
`debug = true` logs diagnostics but never PII.
