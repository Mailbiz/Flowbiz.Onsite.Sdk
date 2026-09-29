# Flowbiz Demo (iOS)

Minimal SwiftUI fake store (SPEC §14) exercising **every public SDK API**:
product list → product detail (`product.view`), cart (`cart.add`,
`cart.item.update`, `cart.sync`, `cart.setcoupon`, `cart.setpostalcode`),
three-step checkout (`checkout.step`, `order.complete`, `order.cancel`),
login (`account.login`, `account.sync`, `logout`), a settings/debug panel
(`setEnabled`, `setPushToken`, `removePushToken`, `flush`, simulated
`handlePush`, `handlePushOpened`) and deep-link recovery with UTM capture
(`handleLink`), with `page.view` tracked on every screen change.

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
  recuperação" opens a journey link (the `basic` hash from
  `shared/recovery-links/vectors.json` plus a journey's 6 UTMs): `handleLink`
  decodes the cart and captures the UTMs, which every later event carries
  as `context.utm` (debug log on a fresh install: `utm context: 6 captured,
  6 active`). The
  hash is minted for appId `77777`; with any other appId `handleLink`
  returns nil, and the UTMs are still captured.
- **Recovery via the OS**: with the app installed in a simulator,
  `xcrun simctl openurl booted "flowbizdemo://recover?utm_source=flowbiz&utm_medium=email&utm_campaign=jornadas%7Ccart%7Ccarrinho-abandonado&_mb_cr_=<hash>"`
  (`|` written as `%7C`, which `URL(string:)` also parses on iOS 13–16). Any
  link works for UTMs, with or without `_mb_cr_`.
- **Push without APNs**: Settings ▸ "Simular push" feeds the canned
  SPEC §10.2 payload from `shared/push-samples/samples.json` into
  `Flowbiz.handlePush` and renders the parsed `FlowbizPush`, including its
  `recoveryPayload`. "Abrir notificação" plays the tap:
  `Flowbiz.handlePushOpened(push)` captures the deep link's UTMs and
  returns the tenant-checked payload.
- **Offline behavior**: the default collectorUrl failing is expected and
  demonstrates the SPEC §9 durable queue + backoff. Logs: os_log subsystem
  `br.com.flowbiz.onsite`, category `FlowbizOnsite` (debug=true).
