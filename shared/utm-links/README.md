# shared/utm-links

UTM ingestion vectors pinning both SDKs' `handleLink` UTM capture
(SPEC §11.1 and §14) to the web tag byte-for-byte. Every `expected` value is
produced by the web tag's own code: `generate.mts` imports
`Mailbiz.Onsite.Tag/libraries/onsite-core/src/url.ts` unchanged and runs a
verbatim copy of `setUtmNavigationContext`
(`onsite-core/src/tracker/tracker-core-invoker.ts`) against an in-memory
store. Never hand-edit `vectors.json` and never generate it with the SDKs'
own ports (that would be circular).

Regenerate after a web change (Node >= 22.18):

```sh
node shared/utm-links/generate.mts [path/to/onsite-core/src/url.ts]
```

## Format

```json
{
  "source": "web revision the vectors were generated from",
  "extract":   [ { "name", "url", "expected" } ],
  "sequences": [ { "name", "steps": [ { "url", "expected" } ] } ],
  "envelope":  { "utm", "context_canonical" }
}
```

- `extract`: each `url` is one evaluation against an **empty** store.
  `expected` is the exact `context.utm` string (`JSON.stringify` of the
  merged UTM object, web key order), or `null` when web never calls
  `setUtmData` — the envelope then has no `utm` key.
- `sequences`: one store carried across the steps, evaluated in order.
  `url: null` is an evaluation with no link (web: a page load without UTMs;
  SDK: a foreground transition or a re-enable while foregrounded — startup
  and a background re-enable load the same set without sliding the expiry).
  `expected` is `context.utm` after that step. A non-null value is also what
  the store holds afterwards.
- `envelope`: `context_canonical` is `JSON.stringify({ utm })` — the outer
  string escaping of the `utm` value inside the canonical envelope.

Expiry (30 days, sliding) is not vector-tested; it is covered by each
platform's core tests against SPEC §11.1.

Consumed by `UtmLinkParserTest` (Android) and `UtmLinkParserSuite` (iOS).
