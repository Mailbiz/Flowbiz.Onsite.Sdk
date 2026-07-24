# Flowbiz Onsite SDK — Specification

Native mobile SDKs (Kotlin/Android, Swift/iOS) that act as a "universal tracker for native mobile": a thin layer equivalent to the Onsite Universal Tracker vendor plus the transport responsibilities of the Mailbiz Tracker Javascript, targeting the existing collector with zero backend changes for tracking.

Reference implementations:
- `../Mailbiz.Onsite.Tag/vendors/onsite-universal-vendor/` — API shape (`mb_track`, `mb_recover_cart`), event catalog, dedup
- `../Mailbiz.Tracker.Javascript/` — wire envelope, identity/session mechanics, queueing
- `../Mailbiz.One.Collector/` — intake contract (`POST /collect`)

---

## 1. Platforms, language, constraints

| | Android | iOS |
|---|---|---|
| Min version | Android 8.0 (API 26) | iOS 13 * |
| Language | Kotlin (language/API level 2.0 floor — conservative for consumers) | Swift 5.9+, `swift-tools-version: 5.9` |
| Dependencies | **Zero** — Kotlin stdlib + platform APIs only | **Zero** — Foundation/UIKit only |
| HTTP | `HttpURLConnection` | `URLSession` |
| Concurrency | single background `ExecutorService` | GCD (`DispatchQueue`) |
| JSON | `org.json` | `Codable` / `JSONSerialization` |
| Persistence | `SharedPreferences` + files in app dir | `UserDefaults` + files in app support dir |
| Lifecycle | `registerActivityLifecycleCallbacks` | `UIApplication` notifications |
| Network reachability | `ConnectivityManager.NetworkCallback` | `NWPathMonitor` (Network framework) |

\* iOS 13 floor retained pending device-share data from the merchant base; revisit raising to iOS 15 before 1.0.

Branding is **Flowbiz**: entry point `Flowbiz`, Android package `com.flowbiz.onsite`, iOS module `FlowbizOnsite`.

## 2. Public API surface (complete)

```kotlin
// Android — all entry points @JvmStatic (Java host apps supported)
Flowbiz.initialize(context, FlowbizConfig(appId = "77777", /* optional: */ collectorUrl, debug, heartbeatIntervalSeconds))
Flowbiz.track(event)                    // typed event, see §5
Flowbiz.logout()                        // clears user identity, rotates session, auto-sends push token removal
Flowbiz.setEnabled(enabled: Boolean)    // opt-out switch, see §12; persisted; default true
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

No callback/handler registration anywhere. The receiving side is **return-style only**: the host app receives deep links and push payloads from the OS, forwards them to the SDK, and branches on the returned value. This mirrors `mb_recover_cart`'s "we provide needed info only" philosophy — the implementing side decides what to do.

### Config

| Field | Required | Default | Notes |
|---|---|---|---|
| `appId` | yes | — | tenant ID, same value as web `app_id` |
| `collectorUrl` | no | `https://collector.mailbiz.one` | full base URL; must be HTTPS (ATS / Android cleartext policy) |
| `debug` | no | `false` | verbose logging; never prints PII (see §12) |
| `heartbeatIntervalSeconds` (Android) / `heartbeatInterval: TimeInterval` (iOS) | no | 60 s | `page.ping` cadence, matches web `pagePingDelay`. Units are explicit per platform idiom: seconds as a `Long` on Android, `TimeInterval` on iOS. Clamped to the 15 s floor and a defensive 24 h ceiling |

Session timeout (30 min), dedup window (20 min), queue cap (1000), and connection timeout (5 s) are **internal constants**, not config knobs.

## 3. Failure policy & threading

**The public API never throws and never crashes the host app.** This is the SDK's first invariant:

- All internal exceptions are caught at the API boundary; failures degrade to a dropped event, never a crash.
- Double `initialize()` is a no-op (first config wins); a warning is logged in `debug`.
- Any call before `initialize()` is a no-op with a `debug` warning — nothing is thrown, nothing is queued.
- Corrupt or unparseable persisted state (queue file, preferences) is discarded and recreated silently.
- Invalid config values are clamped or replaced with defaults, with a `debug` warning.

**Threading guarantees:**

- Every public API is callable from any thread.
- `track()` enqueues and returns immediately; it never blocks the calling thread. All I/O and HTTP run on the SDK's background executor/queue.
- `handlePush` and `handleLink` are pure, synchronous functions — no I/O, no side effects, safe to call anywhere.
- iOS: public types (`Event`, `FlowbizConfig`, `FlowbizPush`, `RecoveryPayload`) are value types conforming to `Sendable` — the SDK is warning-clean under Swift 6 strict concurrency.

## 4. Wire contract

`POST {collectorUrl}/collect`, `Content-Type: application/json`, plus HTTP header `platform: android|ios`. Envelope identical to the JS tracker:

```json
{
  "data": [
    {
      "event": "cart.sync",
      "hash": "<uuid v4 per event>",
      "data": "<JSON-STRING of the event payload, snake_case>",
      "timings": {
        "created_at": "2026-07-21T10:00:00.000Z",
        "sent_at":    "2026-07-21T10:00:00.123Z",
        "timezone":   "-03:00"
      },
      "identity": {
        "user_id":      "<set after accountLogin/accountSync, else omitted>",
        "anonymous_id": "<persistent uuid v4>",
        "session_id":   "<session uuid v4>",
        "visit_count":  3
      },
      "context": {
        "platform":       "android",
        "language":       "pt-BR",
        "screen":         "1080x2400",
        "vendor":         "flowbiz-android-sdk",
        "onsite_version": "<sdk version>",
        "url":            "app://checkout"
      },
      "app_id":    "77777",
      "platform":  "android",
      "v_tracker": "flowbiz-android-sdk",
      "v_version": "android-1.0.0"
    }
  ]
}
```

Collector facts this relies on (verified): all fields optional, `platform` free-form, browser-only context fields safely omitted, `ip`/`user_agent` injected server-side from headers, 3 MB max request, disabled tenants return 200 and drop silently.

`context.url` is only present when the event carries a screen name (see `pageView`), as a synthetic `app://<screen-name>` value so URL-shaped downstream consumers keep working.

Timing semantics: `created_at` is set once at `track()` time; `sent_at` is set/updated at **each transmission attempt**, so for retried events the `created_at`→`sent_at` skew reflects real offline latency. Both use the device wall clock.

## 5. Event catalog — full parity (12 events + heartbeat)

Single typed entry point: Kotlin sealed class / Swift enum with associated values. Compile-time typing replaces the web Yup layer; **no runtime schema validation**, **no enrichment** (RecordManager back-filling is intentionally not ported — mobile integrators build complete typed payloads).

| API event | Wire name | Payload |
|---|---|---|
| `PageView(screenName?)` | `page.view` | `page: { title?: screenName, url?: "app://<screenName>" }` |
| *(automatic)* | `page.ping` | heartbeat, see §8 |
| `AccountLogin(user)` | `account.login` | `user: { user_id, email, phone?, name?, plan?, created_at? }` |
| `AccountSync(user)` | `account.sync` | same as login |
| `ProductView(product)` | `product.view` | `product: { product_id, url?, category?, brand?, variants: [{ sku, price, name?, url?, image_url?, price_from?, stock?, available?, properties?, recovery_properties? }] }` |
| `CartSync(cart)` | `cart.sync` | `cart: { cart_id, subtotal, total, freight, tax, discounts, currency?, coupons?, items?: [CartItem], delivery_address?: Address }` |
| `AddToCart(products)` | `cart.add` | `products: [CartItem]` |
| `CartItemUpdate(...)` | `cart.item.update` | `{ cart_id, product_id, sku, quantity }` |
| `CartSetPostalCode(...)` | `cart.setpostalcode` | `{ cart_id, postal_code }` |
| `CartSetCoupon(...)` | `cart.setcoupon` | `{ cart_id, coupon }` |
| `CheckoutStep(checkout)` | `checkout.step` | `checkout: { cart_id, step, total_steps, step_name }` |
| `OrderComplete(order)` | `order.complete` | `order: { cart_id, order_id?, subtotal, total, freight, tax, discounts, currency?, coupons?, items?, delivery_address?, payment_methods?: [{type, amount}], delivery_methods?: [{type, amount}] }` |
| `OrderCancel(...)` | `order.cancel` | `{ order_id? , cart_id? }` (at least one) |

`CartItem`: `{ product_id, sku, quantity, price, name?, price_from?, category?, brand?, url?, image_url?, properties?, recovery_properties? }`
`Address`: `{ postal_code?, address_line1?, address_number?, address_line2?, city?, state?, country?, neighborhood? }`

Data classes/structs use camelCase properties; serialization emits snake_case wire keys.

Side effect: `AccountLogin`/`AccountSync` also store `user_id`/`email` locally so subsequent events carry `identity.user_id` (web `setUserId` parity).

## 6. Identity & session

- **anonymous_id**: UUID v4, generated on first init, persisted in `SharedPreferences`/`UserDefaults`. Survives app updates; resets on uninstall (matches web cookie-clearing semantics). No Keychain.
- **session_id**: UUID v4. New session when an event fires or the app foregrounds after ≥ 30 min of inactivity; **every tracked event slides the window**, and `page.ping` counts as activity — a foregrounded idle app keeps its session alive (matching web activity tracking). Rotation increments `visit_count`.
- **Inactivity clock**: the 30-min window is measured with **monotonic time** (`SystemClock.elapsedRealtime()` / `ContinuousClock`), never wall clock — user clock changes, timezone travel, and NTP corrections must not rotate or immortalize sessions. Across process restarts (where monotonic time resets) a persisted wall-clock timestamp of the last activity is the fallback. Wall clock is used only for `timings`.
- **user identity**: `user_id`/`email` stored on account events; cleared by `logout()`.
- **`logout()`**: clears stored user identity, rotates session, and — if a push token was registered — automatically emits the token-removal event. `removePushToken()` remains available standalone (e.g. user disables notifications without signing out).

## 7. Dedup

Per event type, the last sent payload is persisted with a timestamp. An identical payload for the same event type within **20 minutes** is suppressed; a suppressed duplicate renews the window (renew-on-duplicate), so a continuously repeated identical payload stays suppressed until it pauses for 20 minutes. This deliberately diverges from web: the web tracker (`storage.ts`) keeps its dedup entries under a single **25-minute** storage TTL that is renewed by *any* event, while mobile uses a fixed per-event-type 20-minute window with renew-on-duplicate — a deliberate simplification, not a port.

- **Comparison basis**: the serialized `data` payload string only. Envelope fields (`hash`, `timings`, `identity`, `context`) are excluded — they always differ.
- **Exempt from dedup**: `page.ping` (it is identical by design every beat; see §8).

**No empty-cart suppression**: a `cartSync` with zero items always sends — emptying a cart is signal, not noise. (Deliberate divergence from web `EventsState`.)

## 8. Heartbeat

While the app is foregrounded, the SDK emits `page.ping` every `heartbeatInterval` (default 60 s) to keep the session alive server-side, matching web `enableActivityTracking`. Stops in background; resumes on foreground. The ping's `data` payload carries `{"page":{"title":"<last named screen>","url":"app://<last named screen>"}}` once a named `pageView` has occurred in the process, and `{}` before.

`page.ping` is **fire-and-forget**: sent directly when online, dropped on failure, **never persisted to the queue** and exempt from dedup. A flaky network session must not fill the durable queue with heartbeats and evict real events.

## 9. Reliability — persisted queue

- Events append to a **disk-persisted queue** and flush immediately when online — web's send-now behavior with mobile durability.
- **File format: JSON Lines** (one event per line, append-only). O(1) appends; a crash mid-write costs one truncated line, not the file. Unparseable lines are skipped, not fatal. The file is compacted after successful flushes. Single-process access is assumed (the standard FCM service runs in the main process); multi-process host apps are unsupported for now.
- **Batched drain**: a flush sends up to **50 events per request** (well under the 3 MB cap) in queue order. HTTP 413 splits the batch in half and retries.
- **Response handling**:
  - **2xx** → success, dequeue. (3xx is *not* success — a redirect not followed means the event was not ingested.)
  - **4xx except 408/429** → the event is permanently rejected; **drop it** (a poison event must not block the queue).
  - **5xx, 408, 429, timeout, network error** → keep queued, back off.
- **Backoff**: exponential, 1 s doubling to a 60 s cap, reset by any retry trigger. Retry triggers: next `track()` call, app foreground, network restoration (`NetworkCallback` / `NWPathMonitor`), explicit `flush()`. 5 s connection timeout.
- **Delivery semantics: at-least-once.** If the process dies between a successful POST and the dequeue, the batch resends on next launch. `hash` is the per-event idempotency key; the collector side must treat it as such for exact-once accounting.
- Queue cap **1000 events, drop-oldest**. Queue survives app kills and crashes (notably right after `orderComplete`).
- All I/O and HTTP off the calling thread; `track()` never blocks the UI thread (see §3).

## 10. Push (receiving + token relay)

The SDK never integrates FCM/APNs (zero dependencies). The host app owns push setup and delivery; the SDK provides three things:

### 10.1 Token relay
`setPushToken(token)` / `removePushToken()` emit events through the normal `/collect` pipeline (queued, deduped like any event). The SDK **persists the last registered token** so `logout()` can emit the removal event with it.

| Call | Wire event | `data` payload |
|---|---|---|
| `setPushToken` | `push.token.sync` | `{ token, platform: "android"\|"ios" }` |
| `removePushToken` / `logout()` | `push.token.remove` | `{ token, platform }` |

These are **new event types**: the collector passes them through today, but a downstream consumer must eventually be built to associate tokens with users. That backend work is out of SDK scope; this defines its contract.

### 10.2 Push payload contract
A Flowbiz push is an FCM/APNs **data payload** containing the marker key `flowbiz` (snake_case wire, consistent with the rest of the ecosystem). Because FCM data messages are flat `Map<String, String>`, the value of `flowbiz` is a **JSON-encoded string on both platforms** — one contract, one parser:

```json
{
  "flowbiz": "{\"v\":1,\"type\":\"cart_recovery\",\"title\":\"Sua sacola te espera!\",\"body\":\"Finalize sua compra...\",\"deep_link\":\"https://store.com?mb_recovery=...\",\"data\":{\"campaign_id\":\"abc123\"}}"
}
```

Decoded shape:

```json
{
  "v": 1,
  "type": "cart_recovery",
  "title": "Sua sacola te espera!",
  "body": "Finalize sua compra...",
  "deep_link": "https://store.com?mb_recovery=...",
  "data": { "campaign_id": "abc123" }
}
```

`type` is a free-form string — new push kinds require no SDK update. A cart-recovery push carries its `mb_recovery` link in `deep_link`, reusing the `handleLink` decoder. Size note for the sending backend: the entire APNs payload is capped at **4 KB**, and `deep_link` carries an LZ-compressed cart — the compressed link must be budgeted accordingly. This contract is the spec the future push-sending backend must implement.

### 10.3 `handlePush`
`handlePush(rawPayload) -> FlowbizPush?` — parses the marker envelope; returns `FlowbizPush(type, title?, body?, deepLink?, data)` or null if the payload isn't ours (marker absent or undecodable). Called by the app from its `FirebaseMessagingService` / `UNUserNotificationCenter` delegate / launch intent — both on notification tap and on foreground receipt. Presentation and routing are entirely the app's decision.

## 11. Cart recovery (receiving)

`handleLink(url) -> RecoveryPayload?`:

1. App forwards any incoming deep link (App Link / Universal Link entry point).
2. SDK looks for the `mb_recovery` query parameter.
3. Value is decoded with a **native port of LZ-string `decompressFromEncodedURIComponent`** (~100 lines, implemented in-SDK on both platforms — no dependency; must pass the shared test vectors, see §14).
4. Decoded hash `{ t, u, c, its: [[qty, product_id, sku, recovery_properties?]] }` is transformed into:

```
RecoveryPayload {
  cartId: String
  userId: String
  products: [{ productId, sku, quantity, recoveryProperties? }]
}
```

5. Returns null if the param is absent or undecodable. The app restores the cart however it wants — same self-contained, no-server-round-trip flow as web `mb_recover_cart`.

The SDK does **not** adopt the decoded `userId` as its identity — `handleLink` is pure (see §3) and only returns data. If the recovered user signs in, the app's normal `AccountLogin`/`AccountSync` flow sets identity.

Prerequisite for integrators (documented, not SDK work): recovery links must point at a domain the app claims via App Links / Universal Links. If the app isn't installed, the same URL falls back to the existing web recovery flow.

## 12. Privacy & compliance

The SDK transports PII (`email`, `phone`, `name`, purchase history) — compliance is a first-class deliverable, not an afterthought:

- **iOS privacy manifest**: a `PrivacyInfo.xcprivacy` is bundled in the SPM target (mandatory for third-party SDKs since 2024; missing/incomplete manifests cause App Store rejections for host apps). It must declare: the `UserDefaults` required-reason API (reason `CA92.1`), and the collected data types (contact info, identifiers, purchase/product-interaction data). Exact declarations (`NSPrivacyTracking` in particular) to be finalized with legal review before 1.0.
- **Android disclosure**: the SDK publishes a data-collection disclosure document so integrators can complete Google Play's **Data safety** form accurately. Registration in Google's **SDK Console** (Play SDK Index) once public.
- **Opt-out**: `setEnabled(false)` — persisted across launches; while disabled the SDK drops new events, stops the heartbeat, and makes no network calls. Re-enabling resumes normal operation. This is the hook for LGPD/GDPR consent gating; the consent UI/decision itself is the host app's responsibility.
- **Logging**: `debug` logging never prints PII (`email`, `phone`, `name` are redacted).

## 13. Repo layout & distribution

```
Flowbiz.Onsite.Sdk/
├── SPEC.md
├── shared/                  # cross-platform contract — the drift guard
│   ├── fixtures/            #   event input → expected envelope JSON pairs
│   ├── lzstring-vectors/    #   compressed input → expected recovery payload
│   └── push-samples/        #   raw push payload → expected FlowbizPush
├── android/                 # Gradle project: sdk module + demo app
│   ├── sdk/
│   └── demo/
├── ios/                     # SPM package + demo app
│   ├── Sources/FlowbizOnsite/
│   ├── Tests/
│   └── Demo/
└── Package.swift            # SPM manifest at root pointing into ios/
```

Distribution: **Maven Central** (`com.flowbiz:onsite-sdk`, Sonatype namespace setup required) and **Swift Package Manager** (git tags on this repo). CocoaPods only if a client asks. Version tags shared (`vX.Y.Z`); the two SDKs version in lockstep.

Release engineering:

- Android AAR ships **consumer R8/ProGuard rules** (`consumerProguardFiles`) so release builds of host apps don't strip/rename SDK classes.
- POM carries complete metadata including the license entry; artifacts are **GPG-signed** for Central.
- One **CI pipeline releases both platforms from a single `vX.Y.Z` tag**: publish AAR to Central, cut the SPM release.
- **Decision (flagged)**: the current layout (`Sources/` in this repo) means the iOS SDK is **source-distributed from a public repo** — and the Android sources ride along. If closed-source distribution is required, the SPM route must switch to a binary XCFramework target and the repo split into public-manifest/private-source. Confirm before 1.0.

## 14. Validation

Two layers (no staging/e2e layer for now):

1. **Shared-fixture unit tests** — both SDKs consume `shared/`: identical event inputs must produce equivalent envelope JSON (ignoring uuids/timestamps), identical LZ-string vectors must decode to identical recovery payloads, identical push samples must parse identically. This is the mechanism that keeps two hand-written SDKs behaviorally identical. **These run in CI on both platforms on every PR** — the drift guard only guards if it's enforced.
2. **Demo apps** — a minimal fake store per platform (product screen, cart, checkout, login) exercising every public API, including deep-link recovery and simulated push payloads.

## 15. Explicitly out of scope

- Field enrichment (RecordManager port) and runtime schema validation (Yup port)
- Empty-cart `cartSync` suppression
- FCM/APNs integration, notification display, token acquisition
- Push-sending backend and token-consuming backend (contract defined in §10, implementation elsewhere)
- Collector/backend changes of any kind
- Web-view bridge, React Native / Flutter wrappers
- Config knobs for session timeout, dedup window, queue size
- Consent management UI (host app's responsibility; SDK provides `setEnabled`, see §12)
- CocoaPods (until requested), staging e2e test infrastructure
