# shared/fixtures

Cross-platform contract fixtures: typed event construction input → expected wire
payload pairs. Both SDKs (Android and iOS) consume every `*.json` file here in
their unit tests.

## Format

```json
{
  "name": "cart_sync_full",
  "event": "cartSync",
  "input": { "...": "canonical camelCase construction values" },
  "expected": {
    "wire_event": "cart.sync",
    "data": { "...": "exact snake_case wire payload object" },
    "data_canonical": "exact canonical wire string, byte-for-byte",
    "identity_user_id": "account events only: identity.user_id of the envelope"
  }
}
```

- `event` names the typed constructor (the API event, lowerCamelCase).
- Optional top-level `baseUri`: the `FlowbizConfig.baseUri` the harness passes
  to the serializer (path resolution). Absent means no base.
- `input` uses the camelCase property names of the data classes/structs;
  each platform's test suite maps it onto the typed constructors. `pageView`
  input keys are `path` and `title`.
- Tests serialize the constructed event, parse the produced `data` JSON string
  and structurally compare against `expected.data` — key order is irrelevant,
  numbers compare by value (`0` == `0.0`).
- Tests additionally compare the produced `data` string **byte-for-byte**
  against `expected.data_canonical`. Both serializers emit canonical JSON
  (`CanonicalJson.kt` / `CanonicalJSON.swift`): keys sorted by UTF-16 code
  units, `JSON.stringify`-compatible number rendering (`19.0` → `19`,
  `10000000` fixed notation, `1e21` → `1e+21`, `-0.0` → `0`, shortest
  round-trip digits) and minimal escaping (raw slashes, raw unicode). Any
  future number/escaping divergence on either platform fails this check.
  `data_canonical` is generated from `expected.data` with node (the web
  tracker's `JSON.stringify` is the reference): recursive key sort +
  `JSON.stringify` of each scalar.
- Optional fields absent from `input` must be entirely absent from the wire
  (`"key": null` never appears).
- Account events go through `UserSanitizer` first, the port of the web's
  account pipeline (the universal vendor's `userSchema`, then onsite-core's
  `sanitizeAccountUser`): `user_id` and `email` lowercased, an invalid email
  and a `user_id` that identifies nobody left out. `expected.identity_user_id`
  is the envelope's `identity.user_id` from that event on (`user_id`, or the
  email without one), also what the SDK stores. `"dropped": true` replaces
  `data`, `data_canonical` and `identity_user_id` when neither is left: the
  event is not sent and the identity does not change.
- One deliberate divergence from the web, pinned by
  `account_login_email_without_at`: the web validates the user with yup
  before sanitizing, so an email that fails yup's `.email()` (no `@`, a
  space: `"maria"`) rejects the whole account event there, valid `user_id`
  or not. The SDK only leaves that email out and still sends the event: an
  identified user is worth more than strict parity. (An email yup accepts
  but the sanitizer rejects, `maria@gmail`, loses only the email on both.)

Covered edge cases: pageView with path+title, path only, title only, an empty
call, and an absolute URL with no `baseUri`; productView and addToCart with
relative/protocol-relative/absolute URLs resolved against `baseUri`; cartSync
full vs empty-cart; productView multi-variant with nested `properties` /
`recovery_properties`; orderComplete with payment/delivery methods and minimal;
account events with mixed case, only an email, only a `user_id`, an invalid
email, an email the web's yup validation rejects, a placeholder `user_id`, a `user_id` that is another email or the same
one, and no valid identity at all; orderCancel with only `order_id`, only
`cart_id`, and both ids; multi-item
addToCart; and number/escaping edge cases (`19.99`, `0.1`, whole-number double
`19.0`, `10000000`, `1e21`, `1e-7`, `-0.0`, URLs with slashes, unicode
including non-BMP emoji) in `cart_sync_number_edge_cases`.

## Envelope and collector contract

The fixtures pin `data`; the envelope around it is the JS tracker's, sent as
`POST {collectorUrl}/collect` with `Content-Type: application/json`, an HTTP
header `platform: android|ios` and a body `{"data":[entry, …]}` of up to 50
entries. Each entry:

- `event` (wire name), `hash` (UUID v4 per event), and `data`: the payload as
  a JSON **string** (the `data_canonical` form), not a nested object.
- `timings`: `created_at` is set once at `track()`; `sent_at` is restamped at
  every send attempt, so the gap between them is the offline delay. Both are
  device wall clock, ISO-8601 UTC with milliseconds; `timezone` is the UTC
  offset, e.g. `-03:00`.
- `identity`: `anonymous_id`, `session_id`, `visit_count`, and `user_id` from
  an `accountLogin`/`accountSync` until `logout()` (the user's `user_id`, or
  the email without one, as the web's `setUserId(user_id || email)`).
- `context`: `platform`, `language`, `screen`, `vendor`
  (`flowbiz-<platform>-sdk`), `onsite_version`, and when set: `url` (resolved
  URL of the latest `pageView` with a path or title), `baseuri`, `recoveryUrl`,
  `utm` (a JSON string, as the web sends it). They ride on every entry, pings
  and push-token events included: MessageBuilder reads `baseuri` and
  `recoveryUrl` off the cart event to build recovery links.
- `app_id`, `platform`, `v_tracker` (= `vendor`), `v_version`
  (`<platform>-<sdk version>`).

Wire events outside the typed catalog: `page.ping` (`data` is
`{"page":{"title","url"}}` of the latest page view, `{}` before one) and
`push.token.sync` / `push.token.remove` (`{"platform","token"}`), for the
backend that will associate push tokens with users.

The SDK relies on these collector facts: every field is optional and
`platform` is free-form (browser-only context fields are simply absent);
`ip` and `user_agent` are derived server-side from the request; a request is
capped at 3 MB. The collector answers 200 to everything, malformed bodies and
unknown or disabled tenants included: check ingestion in the indexes, not by
the status.

Backend facts the fixtures pin or rely on: `coupons` is one string (the
backend's `Coupons` is a `string`; an array makes Cart.Worker drop the event);
`user.created_at` must parse as ISO 8601 or the account event is dropped; a
`cart.sync` without `items` keeps the stored products, `items: []` empties
them; no cart email goes out until an account event ties the `anonymous_id`
to a contact; an `order.complete` whose `order_id` is absent or blank closes
the cart without crediting the order's `context.utm` (one with a real id
replaces the cart's UTMs with its own), and `order_id` `"0"` closes nothing.
`identity.visit_count` is sent as a number, as on web, but the
collector reads a string, so it is lost on both.

Responses: 2xx is delivered; 5xx, 408, 429 and network errors are retried with
backoff; a 413 splits the batch; entries rejected with any other 4xx or a 3xx
are dropped. An entry still queued 7 days after its `created_at` is dropped when the
queue loads, never sent: the backend reads `created_at` as the cart's last
update. Delivery is at-least-once (a batch is resent if the app dies
between the POST and the dequeue), and the collector does not deduplicate on
`hash`, so a resent event can be ingested twice.
