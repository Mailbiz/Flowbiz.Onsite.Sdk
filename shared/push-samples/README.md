# shared/push-samples

The Flowbiz push payload contract, for the backend that sends pushes, and the
samples that hold both SDKs' `handlePush` to it.

## Contract

A Flowbiz push is an FCM data message / APNs payload with a top-level
`flowbiz` key. Its value is a JSON object encoded as a **string** on both
platforms, because FCM data values can only be strings (one contract, one
parser):

```json
{
  "flowbiz": "{\"v\":1,\"type\":\"cart_recovery\",\"title\":\"Sua sacola te espera!\",\"body\":\"Finalize sua compra...\",\"deep_link\":\"https://store.com/carrinho?utm_source=flowbiz&_mb_cr_=...\",\"data\":{\"campaign_id\":\"abc123\"}}"
}
```

- `type` is required and non-empty, and free-form: a new kind of push needs no
  SDK update.
- `v` (contract version, default 1), `title`, `body`, `deep_link` and `data`
  (an object) are optional. Unknown fields and versions are tolerated.
- A cart-recovery push carries its recovery link (see
  `../recovery-links/README.md`) in `deep_link`. Campaign UTMs belong in
  `deep_link` too: `handlePushOpened` captures them when the user taps.
- APNs caps the whole payload at 4 KB, and the `_mb_cr_` value is a
  base64-encoded cart: budget the link accordingly.

## Samples

`samples.json` is an array of cases:

- `payload` — the raw push payload as the OS hands it to the host app
  (FCM: flat `Map<String, String>`; APNs: `userInfo`).
- `expected` — the parsed push (`version`, `type`, `title`, `body`,
  `deepLink` as the **raw string** the parser keeps, `data` object), or
  `null` when the payload is not ours.
- `expected_android` / `expected_ios` — platform overrides. Used only by
  `non_string_marker_dict`: a dictionary marker value cannot occur inside
  FCM's string-valued map (Android → null) but can occur in APNs userInfo
  (iOS tolerates it leniently).
- `expected_recovery` — for the cart-recovery sample: the
  `RecoveryPayload` produced by running the push's `deep_link` through the
  `handleLink` decoder. The `_mb_cr_` value in that deep link is plain
  base64 (see `../recovery-links/README.md`).

Consumed by `PushParserTest` (Android) and `PushParserSuite` (iOS).
