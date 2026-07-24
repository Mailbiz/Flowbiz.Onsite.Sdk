# shared/push-samples

Push payload samples: raw push payload → expected `handlePush` result
(SPEC §10.2/§10.3 and §14). Both SDKs must parse these identically.

`samples.json` is an array of cases:

- `payload` — the raw push payload as the OS hands it to the host app
  (FCM: flat `Map<String, String>`; APNs: `userInfo`). The `flowbiz`
  marker value is a JSON-encoded **string** per the SPEC §10.2 contract.
- `expected` — the parsed push (`version`, `type`, `title`, `body`,
  `deepLink` as the **raw string** the parser keeps, `data` object), or
  `null` when the payload is not ours.
- `expected_android` / `expected_ios` — platform overrides. Used only by
  `non_string_marker_dict`: a dictionary marker value cannot occur inside
  FCM's string-valued map (Android → null) but can occur in APNs userInfo
  (iOS tolerates it leniently).
- `expected_recovery` — for the cart-recovery sample: the
  `RecoveryPayload` produced by running the push's `deep_link` through the
  `handleLink` decoder. The `mb_recovery` value in that deep link was
  compressed with the real lz-string 1.4.4 library (see
  `../lzstring-vectors/README.md`).

Consumed by `PushParserTest` (Android) and `PushParserSuite` (iOS).
