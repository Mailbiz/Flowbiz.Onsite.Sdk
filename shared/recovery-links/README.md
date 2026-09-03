# shared/recovery-links

Cart-recovery link vectors pinning both SDKs' `handleLink` decoders
(SPEC §11 and §14) to the link MessageBuilder emits and the web tag reads:
`?utm_source=<mailbiz|flowbiz…>&_mb_cr_=<base64 of UTF-8 JSON>`, hash
shape `{ t, u, c, its: [[qty, product_id, sku, recovery_properties?]] }`.

`vectors.json` is an array of `{ name, url, appId, expected, hash_json? }`:

- `url` is fed verbatim to `RecoveryLinkParser.parse(url, expectedAppId)`.
- `appId` is the configured tenant (`null` = not initialized: the tenant
  check is skipped, SPEC §3 purity).
- `expected` is the `RecoveryPayload` (`recoveryProperties: null` when
  absent), or `null` when the link must be rejected.
- `hash_json` is documentation only: the compact JSON that was base64-encoded.

Regenerate a hash with
`python3 -c 'import base64,sys; print(base64.b64encode(sys.stdin.read().encode()).decode())'`.

Consumed by `RecoveryLinkParserTest` (Android) and `RecoveryLinkSuite` (iOS).
