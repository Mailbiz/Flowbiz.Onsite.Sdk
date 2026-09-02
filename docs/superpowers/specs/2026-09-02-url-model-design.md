# URL model, recovery context and `_mb_cr_` parity — design

Date: 2026-09-02
Status: approved in discussion, pending written review
Scope: both SDKs (Android, iOS), shared fixtures, demo apps, SPEC.md, README

## 1. Problem

The SDK today sends a synthetic `app://<screenName>` as `context.url` /
`page.url`, sends no `context.baseuri` and no `context.recoveryUrl`, and
parses recovery links as `mb_recovery` + LZ-string. Verified against the
sibling repos (web tracker, collector, event engines, MessageBuilder):

1. Nothing server-side reads `context.url` or `page.url`. They are indexed as
   text and never queried. The `app://` value is harmless but buys nothing.
2. MessageBuilder builds the cart-recovery link from the **cart event's own
   context**: `context.recoveryUrl` wins; otherwise `context.baseuri` plus a
   hardcoded per-vendor cart path; for universal / woocommerce / nuvemshop /
   wake it uses `recovery_properties.url` of the first cart item. The SDK
   sends none of these, so a cart tracked from an app produces a link whose
   base is the literal fallback `#`. This is the actual blocker for "open the
   app when installed".
3. MessageBuilder emits `_mb_cr_=<base64 JSON>` plus `utm_source`, and the web
   tag reads exactly that. No service emits `mb_recovery` or LZ-string. The
   SDK's `handleLink` therefore returns nil for every real link.

Target case for this design: a store that has a website running the onsite
tag **and** a native app. App-only stores (no web domain to claim) are out of
scope; see §9.

## 2. Goals

- One URL shape for web and app events: absolute `https://` URLs, so
  downstream code never has to interpret a platform-specific scheme.
- Apps pass **paths** for everything URL-shaped and the SDK resolves them
  against a configured base. Absolute URLs still pass through.
- Every event carries `context.baseuri`, `context.recoveryUrl` (when set) and
  `context.url`, matching the web tracker's payload context.
- `handleLink` accepts the link the backend actually emits.
- Open-in-app with browser fallback needs zero backend work: an `https`
  recovery link on a domain the app claims (Universal Links / App Links) is
  opened in the app by the OS, in the mobile browser when the app is absent,
  and is an ordinary link on desktop. The SDK does not implement any of this;
  it only guarantees the link is `https` on the integrator's domain.

## 3. Config

Two new `FlowbizConfig` fields on both platforms.

| Field | Required | Validation | Wire |
|---|---|---|---|
| `baseUri` | yes | absolute `https://` origin, no path, no query, no fragment; a single trailing `/` is stripped | `context.baseuri` on every event |
| `recoveryUrl` | no | absolute `https://` URL; may carry a path and query; fragment stripped | `context.recoveryUrl` on every event when set |

Failure policy (SPEC §3, unchanged in spirit): an invalid `baseUri` or
`recoveryUrl` is a **config error**. In `debug` it is logged loudly at
`initialize`. In both debug and release the field is replaced by `nil` and
the SDK keeps working: with no `baseUri`, path resolution (§5) passes values
through unchanged, so events still flow. `baseUri` is declared "required" in
the API (non-optional constructor argument) because the store-with-website
case always has one; the nil fallback exists only so a bad value never
crashes the host.

`baseUri` is **not** compared against `collectorUrl` or the recovery link's
host. Different subdomains for site and app links are legitimate.

Integrator prerequisite, documented in README and SPEC (not SDK work):
`recoveryUrl` (or, when absent, `baseUri`) must be on a domain the app claims
via `apple-app-site-association` / `assetlinks.json`, and the app must route
that URL to `Flowbiz.handleLink`. Custom schemes (`myapp://`) must not be used
for recovery links because they have no browser fallback.

## 4. Context on every event

`EnvelopeBuilder` on both platforms stamps into `context`:

- `baseuri`: the validated `baseUri`.
- `recoveryUrl`: the validated `recoveryUrl`, omitted when nil.
- `url`: the resolved URL of the most recent `pageView` in this process,
  omitted until the first `pageView`. This changes current behaviour, where
  `context.url` is present only on events that carry a screen name. Web
  stamps the current location on every event; this matches it.

`page.ping` keeps its current page block (`{"page":{"title","url"}}` after
the first named page view, `{}` before), with `url` now the resolved URL.

## 5. Path resolution

One internal resolver, `UrlResolver` (`UrlResolver.kt` / `UrlResolver.swift`),
applied at serialization time to every URL-shaped field the app hands the
SDK:

- `page.url` (from `pageView(path:)`)
- `product.url`
- `variant.url`, `variant.image_url`
- `cart item.url`, `cart item.image_url`

Rules, given `base` = validated `baseUri` (or nil) and `value` = the
app-supplied string:

| Input | Output |
|---|---|
| nil | nil (field omitted) |
| empty string | nil (field omitted) |
| has a scheme (`^[A-Za-z][A-Za-z0-9+.-]*:`) | unchanged |
| protocol-relative `//host/...` | `https:` + value |
| starts with `/` and base set | base + value |
| no leading `/` and base set | base + `/` + value |
| base nil | unchanged |

Query strings and fragments in the value are preserved. Nothing is stripped
or percent-encoded by the SDK: the backend already strips UTM parameters from
catalog URLs, and web vendors send raw values too. Whitespace is trimmed.

`recovery_properties` is an opaque JSON object and is **not** resolved; the
universal-vendor convention of a `url` key inside it is the integrator's own
value.

## 6. `pageView` API

`Event.pageView(screenName:)` is replaced by:

```swift
// iOS
case pageView(path: String?, title: String? = nil)
```

```kotlin
// Android
data class PageView(val path: String? = null, val title: String? = null) : Event()
```

Wire mapping for `page.view`:

| Input | `page.url` | `page.title` |
|---|---|---|
| `path` set, `title` set | resolved path | title |
| `path` set, `title` nil | resolved path | omitted |
| `path` nil, `title` set | omitted | title |
| both nil | omitted | omitted |

`context.url` and the heartbeat's page block follow the same resolved value.
The `app://` synthetic scheme is removed. The `page.path` field the web
tracker derives by string splitting is **not** emitted; nothing reads it.

Dedup (SPEC §7) keys on the serialized payload as today, so two page views of
the same path within the window still dedupe.

## 7. Recovery link parsing

`handleLink` / `RecoveryLinkParser` change to the web contract:

1. Find the first `_mb_cr_` pair in the query string (fragment ignored, as
   the web `getQueryParameters` does).
2. Require a `utm_source` pair whose value contains `mailbiz` or `flowbiz`
   (case-insensitive). Missing or other → nil, matching web `isValidUtm`.
3. Decode the value as base64 → UTF-8 → JSON. Tolerance: try the raw value,
   then a percent-decoded variant (`%XX` only), then the variant with `' '`
   restored to `+`. First one that yields a valid payload wins. Base64
   padding may be absent (`=` is often dropped or encoded); pad before
   decoding.
4. Validate the hash as today: `t`, `u`, `c` non-empty strings, `its` a
   non-empty array; per item `[qty, product_id, sku, recovery_properties?]`
   with the existing coercions.
5. Tenant check: when the SDK is initialized, `t` must equal the configured
   `appId`, else nil with a debug log (web `appId === hash.t`). Before
   `initialize`, `handleLink` stays pure and skips the check, so it remains
   callable from a cold launch path.

`RecoveryPayload` is unchanged. `LZString.kt` / `LZString.swift` and their
tests are deleted. `shared/lzstring-vectors/` becomes
`shared/recovery-links/` with full URL vectors (positive and negative cases:
missing utm, wrong utm, missing param, bad base64, tenant mismatch,
percent-encoded, unpadded).

Push contract (SPEC §10.2): `deep_link` carries the same `https://...?_mb_cr_=...&utm_source=...`
link; the 4 KB APNs note is reworded for base64 instead of LZ.

## 8. Demo apps

Both demos:

- Configure `baseUri: "https://www.belamodastore.com.br"` and
  `recoveryUrl: "https://www.belamodastore.com.br/carrinho"`.
- Switch every product/variant/cart URL to a path (`/camisa-linho-azul-marinho`)
  so the resolver is exercised end to end.
- Track `pageView(path:title:)` per screen (`/`, `/produto/<id>`, `/carrinho`,
  `/checkout/<step>`, `/login`, `/ajustes`).
- "Simular link de recuperação" uses a `_mb_cr_` vector from
  `shared/recovery-links/`. The iOS README's `simctl openurl` example and the
  Android `adb shell am start` example use the same link on the custom demo
  scheme (the scheme is still fine for the demo; production uses Universal
  Links / App Links, and the README says so next to the example).

## 9. Out of scope, recorded for later

- **App-only stores.** Need a Flowbiz-hosted link domain claimed by the app
  plus a fallback landing page (store listing). Requires a new backend
  component and a tenant setting; nothing in Mailbiz.One.App stores a store
  URL, bundle id or package name today.
- **`PageEvent` model bug** in Mailbiz.One.Common.Library: every `page.*`
  member is typed as `PageData` instead of `string`, so `page.url` cannot
  deserialize. Harmless today because nobody reads it; will break the first
  server-side consumer of page URLs.
- **`baseuri` without scheme on web.** Reference onsite config sets
  `baseuri: window.location.hostname`; MessageBuilder concatenates it without
  parsing and the collector's redirect then rejects the scheme-less link.
  The mobile SDK enforces `https://` so it never triggers this; the web-side
  issue is separate.
- **Recovery-hash generator tool** already emits `_mb_cr_`; no change needed
  there.

## 10. Testing

Shared, run on both platforms in CI (SPEC §14 drift guard):

- `shared/fixtures/`: new `page_view_path_and_title.json`,
  `page_view_path_only.json`, `page_view_title_only.json`; existing
  product/cart fixtures gain sibling `*_relative_urls.json` variants whose
  `input` uses paths and whose `expected` has resolved URLs. Fixture files
  gain an optional top-level `"baseUri"` so the harness knows what to
  configure.
- `shared/recovery-links/vectors.json`: positive and negative link vectors
  as listed in §7, each with `url`, `appId` (or null for "not initialized")
  and `expected` payload or null.

Platform unit tests:

- `UrlResolver`: table test over §5, including trailing-slash base, empty
  string, whitespace, scheme-like `mailto:`, protocol-relative.
- `FlowbizConfig`: valid/invalid `baseUri` and `recoveryUrl`, trailing slash
  strip, fragment strip, `http://` rejected.
- `EnvelopeBuilder`: a non-page event carries `baseuri` and `recoveryUrl`;
  `url` absent before any page view and present after; `recoveryUrl` absent
  when not configured.
- Heartbeat: page block uses the resolved URL.
- `RecoveryLinkParser`: shared vectors plus the tenant-check split
  (initialized vs not).

Demo: manual run on simulator/emulator with the deep-link command from the
README, confirming the recovery sheet renders the decoded cart.

## 11. Documentation changes

- SPEC.md: §2 API (pageView signature, config table), §4 wire example and
  the `context.url` paragraph, §5 pageView row, §8 heartbeat, §10.2 push
  sample, §11 rewritten for `_mb_cr_`, §13 repo layout (`shared/recovery-links/`),
  §14 fixtures.
- README: integration steps gain the Universal Links / App Links
  prerequisite with the exact file names, the `baseUri` / `recoveryUrl`
  config, and the new deep-link test command. Every `mb_recovery` mention is
  replaced.
- Demo READMEs: same command update.
