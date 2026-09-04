import SwiftUI
import FlowbizOnsite

/// Fake-store demo app (SPEC §14): exercises every public SDK API against
/// the production wiring (UserDefaults, JSONL queue file, UIKit lifecycle
/// notifications, real clock/network). Plain SwiftUI, zero third-party
/// dependencies; the goal is clarity of the SDK call sites, not UX.
///
/// The collectorUrl is selected per build configuration: Debug builds point
/// at staging (collector.stg.mbzlabs.me), Release builds at production —
/// the host-app side of the environment-switch pattern (the SDK itself only
/// exposes a neutral collectorUrl override). Failed POSTs are harmless
/// either way; they demonstrate the SPEC §9 durable queue + backoff. Watch
/// the os_log category `FlowbizOnsite` (debug=true) to see the pipeline.
@main
struct FlowbizDemoApp: App {

    @StateObject private var store = DemoStore()

    init() {
        // SPEC §2: initialize once at launch; debug=true, placeholder appId,
        // collector selected by build configuration.
        #if DEBUG
        let collectorUrl = "https://collector.stg.mbzlabs.me"
        #else
        let collectorUrl = "https://collector.mailbiz.one"
        #endif
        Flowbiz.initialize(FlowbizConfig(
            appId: "77777",
            baseUri: "https://www.belamodastore.com.br",          // spec §3: store origin, prepended to path URLs
            collectorUrl: collectorUrl,
            debug: true,
            recoveryUrl: "https://www.belamodastore.com.br/carrinho" // spec §3: where recovery links land (Universal Link domain)
        ))
    }

    var body: some Scene {
        WindowGroup {
            ProductListView()
                .environmentObject(store)
                .onOpenURL { url in
                    // SPEC §11: forward every incoming deep link and branch on
                    // the return value (custom scheme flowbizdemo:// here; a
                    // real integration uses Universal Links).
                    store.recovery = DemoStore.RecoveryResult(
                        source: url.absoluteString,
                        payload: Flowbiz.handleLink(url)
                    )
                }
                .sheet(item: $store.recovery) { result in
                    RecoveryView(result: result)
                        .environmentObject(store)
                }
        }
    }
}
