# shared/recovery-links

Cart-recovery link vectors pinning both SDKs' `handleLink` decoders to the
link MessageBuilder emits and the web tag reads (`getRecoveryDataFromQuery`):
`?utm_source=<mailbiz|flowbiz…>&_mb_cr_=<base64 of UTF-8 JSON>`, hash
shape `{ t, u, c, its: [[qty, product_id, sku, recovery_properties?]] }`.

- `utm_source` must contain `mailbiz` or `flowbiz` (case-insensitive).
- `_mb_cr_` is plain base64 of the UTF-8 JSON (web:
  `btoa(unescape(encodeURIComponent(json)))`). Percent-encoding, missing
  padding, the URL-safe alphabet and `+` turned into a space are tolerated.
- `t` is the tenant: once the SDK is initialized it must equal `appId`.
  `u` is the user id, `c` the cart id, `its` the items.
- A link without `_mb_cr_`, with an undecodable value, a bad `utm_source` or
  another tenant decodes to `null`.

`vectors.json` is an array of `{ name, url, appId, expected, hash_json? }`:

- `url` is fed verbatim to `RecoveryLinkParser.parse(url, expectedAppId)`, which
  first removes tabs/newlines and trims the ends, as a browser's `location.href`.
- `appId` is the configured tenant (`null` = not initialized: the tenant
  check is skipped).
- `expected` is the `RecoveryPayload` (`recoveryProperties: null` when
  absent), or `null` when the link must be rejected.
- `hash_json` is documentation only: the compact JSON that was base64-encoded.

Regenerate a hash with
`python3 -c 'import base64,sys; print(base64.b64encode(sys.stdin.read().encode()).decode())'`.

Consumed by `RecoveryLinkParserTest` (Android) and `RecoveryLinkSuite` (iOS).
