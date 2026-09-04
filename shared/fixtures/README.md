# shared/fixtures

Cross-platform contract fixtures: typed event construction input → expected wire
payload pairs. This is the drift guard of SPEC.md §14 — both SDKs (Android and
iOS) consume every `*.json` file here in their unit tests.

## Format

```json
{
  "name": "cart_sync_full",
  "event": "cartSync",
  "input": { "...": "canonical camelCase construction values" },
  "expected": {
    "wire_event": "cart.sync",
    "data": { "...": "exact snake_case wire payload object" },
    "data_canonical": "exact canonical wire string, byte-for-byte"
  }
}
```

- `event` names the typed constructor (SPEC §5 API event, lowerCamelCase).
- Optional top-level `baseUri`: the `FlowbizConfig.baseUri` the harness passes
  to the serializer (spec §5 path resolution). Absent means no base.
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

Covered edge cases: pageView with path+title, path only, title only, an empty
call, and an absolute URL with no `baseUri`; productView and addToCart with
relative/protocol-relative/absolute URLs resolved against `baseUri`; cartSync
full vs empty-cart; productView multi-variant with nested `properties` /
`recovery_properties`; orderComplete with payment/delivery methods and minimal;
orderCancel with only `order_id`, only `cart_id`, and both ids; multi-item
addToCart; and number/escaping edge cases (`19.99`, `0.1`, whole-number double
`19.0`, `10000000`, `1e21`, `1e-7`, `-0.0`, URLs with slashes, unicode
including non-BMP emoji) in `cart_sync_number_edge_cases`.
