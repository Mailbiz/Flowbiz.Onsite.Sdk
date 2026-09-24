# Flowbiz Demo (iOS)

Minimal SwiftUI fake store (SPEC §14) exercising **every public SDK API**:
product list → product detail (`product.view`), cart (`cart.add`,
`cart.item.update`, `cart.sync`, `cart.setcoupon`, `cart.setpostalcode`),
three-step checkout (`checkout.step`, `order.complete`, `order.cancel`),
login (`account.login`, `account.sync`, `logout`), a settings/debug panel
(`setEnabled`, `setPushToken`, `removePushToken`, `flush`, simulated
`handlePush`, `handlePushOpened`) and deep-link recovery + UTM capture
(`handleLink`), with `page.view` tracked on every screen change. Every
`Flowbiz.*` call site carries a one-line comment naming the SPEC section it
demonstrates.

The demo is intentionally **not** part of the root `Package.swift` build
graph (an iOS app can't build as a plain SPM target on a macOS host) — it
is a source set plus an XcodeGen spec; you create the app project locally.

## Run with XcodeGen (recommended)

```sh
brew install xcodegen   # once
cd ios/Demo
xcodegen generate       # writes FlowbizDemo.xcodeproj (gitignored)
open FlowbizDemo.xcodeproj
```

Select an iOS Simulator and Run. The local package dependency on the repo
root (`path: ../..`) is wired by `project.yml`.

## Run without XcodeGen (manual Xcode setup)

1. Xcode ▸ File ▸ New ▸ Project ▸ iOS App (SwiftUI, name it e.g.
   `FlowbizDemo`, iOS 15+). Create it anywhere *outside* the repo, or add
   its `.xcodeproj` to `.gitignore`.
2. Delete the template's generated `ContentView.swift` / `*App.swift`.
3. Add the files under `ios/Demo/Sources/` to the app target
   (File ▸ Add Files…, "Copy items" **off** to keep editing in-repo).
4. File ▸ Add Package Dependencies ▸ Add Local… ▸ select the **repo root**
   (the folder containing `Package.swift`); add the `FlowbizOnsite` product
   to the app target.
5. In the target's Info tab add a URL Type with scheme `flowbizdemo`
   (deep-link entry point, SPEC §11).
6. Run on an iOS Simulator.

## Trying recovery & push

- **Recovery deep link without any infra**: Settings ▸ "Simular link de
  recuperação" opens a MessageBuilder-shaped journey link — the `basic`
  hash from `shared/recovery-links/vectors.json` plus the full UTM set
  (`messagebuilder_journey_cart_recovery` in
  `shared/utm-links/vectors.json`). `handleLink` decodes the cart *and*
  captures the UTMs (SPEC §11.1): every later event, e.g. the `cart.sync`
  of "Restaurar carrinho", carries them as `context.utm`
  (`{"utm_source":"flowbiz","utm_medium":"email","utm_campaign":"jornadas|cart|carrinho-abandonado",…}`);
  the debug log shows `utm context set: 6 captured, 6 active`. The hash is
  minted for the demo's placeholder appId `77777`: initialized with any
  other appId, the tenant check makes `handleLink` return nil (the sheet
  shows the nil case, no "Restaurar carrinho") while the UTMs are still
  captured.
- **Recovery via the OS**: with the app installed in a simulator,
  `xcrun simctl openurl booted "flowbizdemo://recover?_mb_cr_=<hash>&utm_journey=16&utm_journey_channel=email&utm_source=flowbiz&utm_medium=email&utm_campaign=jornadas%7Ccart%7Ccarrinho-abandonado&utm_journey_type=1"`.
  Write `|` as `%7C`: `URL(string:)` rejects a raw `|` on iOS 13–16, and
  on iOS 17+ a raw `|` makes it re-encode the link's other `%XX` escapes.
  Any link works for attribution — UTMs are captured even when there is
  no `_mb_cr_` (e.g. `flowbizdemo://home?utm_source=google&utm_medium=cpc`).
- **Push without APNs**: Settings ▸ "Simular push" feeds the canned
  SPEC §10.2 payload from `shared/push-samples/samples.json` into
  `Flowbiz.handlePush` and renders the parsed `FlowbizPush`, including its
  `recoveryPayload` (pure: no UTM capture, no tenant check). "Abrir
  notificação" plays the notification tap: `Flowbiz.handlePushOpened(push)`
  runs `handleLink` over the push's raw `deep_link`, so its UTMs are
  captured exactly as Android and web read them (a `URL` round trip of
  `deepLink` cannot guarantee that), and shows the tenant-checked payload
  it returns — nil with an appId other than `77777`, UTMs still captured.
  `handlePush` itself never captures: receiving a push is not a click.
- **Offline behavior**: the default collectorUrl failing is expected and
  demonstrates the SPEC §9 durable queue + backoff. Logs: os_log subsystem
  `br.com.flowbiz.onsite`, category `FlowbizOnsite` (debug=true).
