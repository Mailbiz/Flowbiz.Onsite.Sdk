# shared/lzstring-vectors

LZ-string test vectors pinning both SDKs' native ports of
`decompressFromEncodedURIComponent` against the real JS library
(SPEC §11 and §14).

`vectors.json` is an array of cases:

- `{ name, compressed, expected_decompressed }` — decoding `compressed`
  must yield exactly `expected_decompressed` (which is `""` for several
  garbage cases: that is the reference library's actual output).
- `{ name, compressed, expect_null: true }` — decoding must yield null/nil.

Case families: realistic web-shaped recovery hashes (`recovery_hash_*`,
including recovery_properties, unicode product data, a 25-item cart and
quantity edge cases), recovery-shaped-but-invalid hashes (`invalid_hash_*`
— they decompress fine but `handleLink` must map them to null), plain
strings (unicode, emoji, empty, single char, long repetitive), the
`" "` → `"+"` URL quirk (`space_restored_to_plus_quirk`), and garbage
inputs recorded with the reference library's actual behavior (`garbage_*`,
covering both its `""` and its `null` return paths).

## Regenerating

Vectors were generated with **lz-string 1.4.4** — the exact library the web
tag uses (`Mailbiz.Onsite.Tag/libraries/onsite-core/node_modules/lz-string`)
— under node, never with either SDK's own port (that would be circular
validation). If you add cases, generate `compressed` with that library's
`compressToEncodedURIComponent(...)` and record
`decompressFromEncodedURIComponent`'s real output as the expectation.

Consumed by `LZStringTest` / `RecoveryLinkParserTest` (Android) and
`LZStringSuite` / `RecoveryLinkSuite` (iOS).
