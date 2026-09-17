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
    implementation("br.com.flowbiz:onsite-sdk:0.1.0")
}
```

**iOS (Swift Package Manager):**

```swift
// Package.swift — or Xcode ▸ Add Package Dependencies with the same URL.
.package(url: "https://github.com/Mailbiz/Flowbiz.Onsite.Sdk.git", from: "0.1.0")
```

Both SDKs version in lockstep; one `vX.Y.Z` tag releases both.

## Quickstart

### Public API surface (complete)

```kotlin
// Android — all entry points @JvmStatic (Java host apps supported)
Flowbiz.initialize(context, FlowbizConfig(appId = "77777", baseUri = "https://store.com", /* optional: */ collectorUrl, debug, heartbeatIntervalSeconds, recoveryUrl))
Flowbiz.track(event)                    // typed event, see SPEC §5
Flowbiz.logout()                        // clears user identity, rotates session, auto-sends push token removal
Flowbiz.setEnabled(enabled: Boolean)    // opt-out switch, see SPEC §12; persisted; default true
Flowbiz.setPushToken(token: String)
Flowbiz.removePushToken()
Flowbiz.handlePush(payload: Map<String, String>): FlowbizPush?   // null = not ours
Flowbiz.handleLink(url: Uri): RecoveryPayload?                   // null = no decodable _mb_cr_ link (or utm_source / tenant mismatch)
Flowbiz.flush()                         // force queue flush (optional nicety, fire-and-forget)
```

```swift
// iOS — identical semantics
Flowbiz.initialize(FlowbizConfig(appId: "77777", baseUri: "https://store.com"))
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

### Configuration

`FlowbizConfig` is the only input to `initialize`. Identical on both
platforms; two properties are required, the rest have defaults (Java host
apps get the same defaults via `@JvmOverloads`).

| Property | Type (Android / iOS) | Default | Rules |
|---|---|---|---|
| `appId` | `String` | required | Tenant id, same value as the web `app_id`. Blank → `initialize` is a complete no-op. |
| `baseUri` | `String` | required | Store origin (`https://store.com`), same value as the web `baseuri`. Must be `https://` with a host and no path, query or fragment. Prepended to path-only URLs (SPEC §5) and sent as `context.baseuri`. Invalid → `""`, paths are then sent unresolved. |
| `collectorUrl` | `String` | `https://collector.mailbiz.one` | Full collector base URL; must be `https://` with a host. Invalid → default. Use it to point debug builds at a staging collector. |
| `debug` | `Boolean` / `Bool` | `false` | Verbose SDK logging; never prints PII (SPEC §12). |
| `heartbeatIntervalSeconds` / `heartbeatInterval` | `Long` / `TimeInterval` | `60` | `page.ping` cadence in seconds (SPEC §8). Clamped to a 15 s floor and a 24 h ceiling. |
| `recoveryUrl` | `String?` | `null` / `nil` | Absolute `https://` URL the backend targets with cart-recovery links, on a domain the app claims via App Links / Universal Links (see below). Sent as `context.recoveryUrl`; fragment stripped. Invalid → `null`. |

Invalid values never throw (SPEC §3): each one is sanitized at `initialize`
with a `debug` log line, and the sanitized copy is what the SDK runs with.
Session timeout (30 min), dedup window (20 min), queue cap (1000) and the
connection timeout are internal constants, not configuration (SPEC §2).

### Android

```kotlin
// Application.onCreate
Flowbiz.initialize(this, FlowbizConfig(appId = "77777", baseUri = "https://store.com", recoveryUrl = "https://store.com/carrinho"))

// Track typed events (SPEC §5 catalog: PageView, AccountLogin, AccountSync,
// ProductView, CartSync, AddToCart, CartItemUpdate, CartSetPostalCode,
// CartSetCoupon, CheckoutStep, OrderComplete, OrderCancel)
// URL-shaped fields (page path, product/variant/item url and image_url) may be paths — the SDK prepends baseUri
Flowbiz.track(Event.PageView(path = "/", title = "Home"))
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
Flowbiz.initialize(FlowbizConfig(appId: "77777", baseUri: "https://store.com", recoveryUrl: "https://store.com/carrinho"))

// Track typed events (same catalog as Android)
// URL-shaped fields (page path, product/variant/item url and image_url) may be paths — the SDK prepends baseUri
Flowbiz.track(.pageView(path: "/", title: "Home"))
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
existing web recovery flow (SPEC §11). Set `recoveryUrl` to an https URL on
that claimed domain (typically the cart page); the backend appends
`?utm_source=…&_mb_cr_=…` to it, the OS opens your app if installed, the
mobile browser otherwise, and desktop users get the normal web recovery
flow. The claim files: `https://<domain>/.well-known/apple-app-site-association`
and `https://<domain>/.well-known/assetlinks.json`.

### Consent / opt-out

`Flowbiz.setEnabled(false)` is the LGPD/GDPR consent hook: persisted across
launches; while disabled the SDK drops new events, stops the heartbeat and
makes no network calls. Re-enabling resumes normal operation and re-syncs a
push token registered while disabled (SPEC §12). The consent UI/decision is
the host app's responsibility — the SDK collects by default until told
otherwise.

## Demo apps

Each platform ships a minimal fake store (SPEC §14) that exercises **every
public API** — product list/detail, cart, 3-step checkout, login, a
settings/debug panel (opt-out, push-token relay, flush, simulated SPEC §10.2
push payload) and deep-link cart recovery (real intent/URL plus an in-app
"simulate recovery link" button using the shared recovery-link vectors). Every
SDK call site is commented with the SPEC section it demonstrates. Run them
offline on purpose: failing collector POSTs demonstrate the SPEC §9 durable
queue + backoff.

- **Android**: `cd android && ./gradlew :demo:installDebug` (or open in
  Android Studio and run the `demo` configuration). Deep link:
  `adb shell am start -a android.intent.action.VIEW -d "flowbizdemo://recover?utm_source=flowbiz&_mb_cr_=<hash>"`.
- **iOS**: `ios/Demo/` is a source set + XcodeGen spec (no checked-in
  `.xcodeproj`): `brew install xcodegen && cd ios/Demo && xcodegen generate && open FlowbizDemo.xcodeproj`.
  Manual-Xcode instructions in [ios/Demo/README.md](ios/Demo/README.md).

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

## Development

### Where things live

The two SDKs are mirrored file-for-file: the same file name exists under
`android/sdk/src/main/kotlin/com/flowbiz/onsite/` (Kotlin) and
`ios/Sources/FlowbizOnsite/` (Swift), and every file's header comment names
the [SPEC.md](SPEC.md) section it implements. Change both sides together.

| Concern | Files (Android / iOS) |
|---|---|
| Public surface | `Flowbiz`, `FlowbizConfig`, `Event`, `Models` |
| Engine (wires everything: lifecycle, logout, heartbeat, flush triggers) | `FlowbizCore` |
| Event → wire payload (SPEC §4/§5) | `EventSerializer`, `UrlResolver`, `CanonicalJson`/`CanonicalJSON`, `EnvelopeBuilder` |
| Identity & session (SPEC §6) | `IdentityStore`, `SessionManager`, `Clock` + `AndroidClock`/`SystemClock` |
| Dedup, heartbeat, opt-out (SPEC §7/§8/§12) | `DedupStore`, `HeartbeatScheduler`, `EnabledState` |
| Offline queue & transport (SPEC §9) | `EventQueue`, `FlushController`, `HttpSender`, `Reachability` |
| Push & recovery links (SPEC §10/§11) | `PushTokenStore`, `FlowbizPush`, `RecoveryLinkParser`, `RecoveryPayload` |
| Persistence | `KeyValueStore` + `SharedPreferencesStore`/`UserDefaultsStore` |
| Version stamped into envelopes | `SdkVersion.kt` / `SDKVersion.swift` |

Around the SDK sources:

- `shared/` — the cross-platform **drift guard** (SPEC §14). Both test
  suites load every JSON file here: `fixtures/` (typed event → expected
  wire payload, byte-for-byte), `recovery-links/` (`handleLink` vectors)
  and `push-samples/` (`handlePush` samples). A change that affects the
  wire starts with a fixture here, so both platforms are held to it.
- `android/sdk/src/test/kotlin/com/flowbiz/onsite/` — JUnit 4 tests
  (`*Test.kt`; doubles in `StateTestDoubles.kt` / `TransportTestDoubles.kt`,
  fixture loading in `FixtureSupport.kt`).
- `ios/Tests/FlowbizOnsiteTests/` — Swift Testing suites (`*Suite.swift`;
  doubles in `StateTestSupport.swift` / `TransportTestSupport.swift`,
  fixture loading in `FixtureSupport.swift`).
- `android/demo/` and `ios/Demo/` — the fake-store demo apps (see above).
- `android/sdk/build.gradle.kts` — Maven Central publication (POM,
  signing); `Package.swift` at the root — the SPM manifest pointing into
  `ios/`.
- `.github/workflows/ci.yml` (tests on every PR and push to `main`) and
  `release.yml` (tag-driven publish).

### Running tests

**Android** — needs JDK 17 and an Android SDK with platform/build-tools 35:

```sh
cd android
./gradlew :sdk:testDebugUnitTest                                   # full suite, incl. shared-fixture tests
./gradlew :sdk:testDebugUnitTest --tests 'com.flowbiz.onsite.SessionManagerTest'
./gradlew :sdk:testDebugUnitTest :sdk:assembleRelease :sdk:lint    # exactly what CI runs
```

`:sdk:test --rerun` does not re-run the suite; use `:sdk:testDebugUnitTest --rerun`.
The HTML report lands in `android/sdk/build/reports/tests/testDebugUnitTest/`.

**iOS** — needs Xcode 16.4 or newer (Swift 6 toolchain). Older Xcodes
silently compile the Swift Testing suites away and report green after
running only two XCTest cases, which is why CI asserts a floor of 150
executed tests.

```sh
swift test                                    # macOS host run — fast, no simulator; incl. shared-fixture suites
swift test --filter SessionManagerSuite
xcodebuild test -scheme FlowbizOnsite -destination 'platform=iOS Simulator,name=iPhone 16'   # UIKit code paths
```

If `xcode-select` points at the Command Line Tools, prefix the commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

For an end-to-end check against a collector, run a demo app (see
[Demo apps](#demo-apps)); debug builds point at the staging collector.

### Releasing a new version

Both SDKs version in lockstep and one `vX.Y.Z` tag releases both: the AAR
goes to Maven Central, and the tag itself is the SPM release.

1. **Bump the version** in the three places the release workflow checks —
   all must equal the tag, or nothing is published:
   - `android/sdk/src/main/kotlin/com/flowbiz/onsite/SdkVersion.kt` (`CURRENT`)
   - `ios/Sources/FlowbizOnsite/SDKVersion.swift` (`current`)
   - `android/sdk/build.gradle.kts` (`version`)

   Also update the install snippets at the top of this README, the demo
   `versionName` in `android/demo/build.gradle.kts`, and the version
   mentioned in `android/DATA_DISCLOSURE.md`.
2. **Dry-run the Android artifact** locally and inspect the POM and AAR:
   `cd android && ./gradlew :sdk:publishToMavenLocal` writes to
   `~/.m2/repository/com/flowbiz/onsite-sdk/<version>/`.
3. **Merge to `main`** through a PR with CI green.
4. **Tag and push** — this is the release trigger:

   ```sh
   git tag -a v0.2.0 -m "v0.2.0"
   git push origin v0.2.0
   ```

5. The **Release workflow** (`.github/workflows/release.yml`) verifies the
   tag against the three version constants, runs the Android unit tests,
   builds and GPG-signs the AAR + sources + javadoc jars and uploads them to
   Maven Central staging. iOS needs no artifact: SPM resolves the tag.
6. **Publish the staged deployment** in the Sonatype Central Portal (manual
   until that step is automated). Artifacts are usually visible on Maven
   Central within the hour.

One-time prerequisites, still pending (see the TODOs in `release.yml`): the
`br.com.flowbiz` namespace verified in the Central Portal (DNS TXT record on
flowbiz.com.br), the repository secrets `CENTRAL_USERNAME`,
`CENTRAL_PASSWORD`, `SIGNING_IN_MEMORY_KEY` and
`SIGNING_IN_MEMORY_KEY_PASSWORD`, and the signing key's public half on a
keyserver.
