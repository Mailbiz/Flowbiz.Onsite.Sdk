# shared/utm-links

`vectors.json` pins both SDKs' UTM capture to the web tag byte for byte. Every
`expected` comes from running the web code itself (onsite-core `Url` and
`setUtmNavigationContext`), never from the SDKs' ports; do not hand-edit it.

- `extract`: one link on an empty store → the exact `context.utm` string, or
  `null` when web sends no `utm`.
- `sequences`: one store across steps; a `null` url is a load with no link
  (in the SDKs: the app coming to the foreground).
- `envelope`: a link and how its `context.utm` is escaped inside the canonical
  envelope.

The web reads `location.href`, already parsed by the browser, so `generate.mts`
feeds it `new URL(link).href`. The SDKs mirror the parser's tab/newline removal
and end trimming, not its escaping, which differs only in a value that fails to
decode and holds a character a browser escapes (a raw space next to a stray `%`).

Regenerate after a web change (Node >= 22.18), then run both platforms' tests:

```sh
node shared/utm-links/generate.mts [path/to/Mailbiz.Onsite.Tag]   # default: sibling checkout
```
