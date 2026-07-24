import SwiftUI
import FlowbizOnsite

/// Fake-store demo app (SPEC §14): exercises every public SDK API against
/// the production wiring (UserDefaults, JSONL queue file, UIKit lifecycle
/// notifications, real clock/network). Plain SwiftUI, zero third-party
/// dependencies; the goal is clarity of the SDK call sites, not UX.
///
/// The collectorUrl is left at its default. Offline (or with the placeholder
/// appId rejected upstream) the POSTs fail harmlessly — which is the point:
/// it demonstrates the SPEC §9 durable queue + exponential backoff. Watch
/// the os_log category `FlowbizOnsite` (debug=true) to see the pipeline.
@main
struct FlowbizDemoApp: App {

    @StateObject private var store = DemoStore()

    init() {
        // SPEC §2: initialize once at launch; debug=true, placeholder appId,
        // default collectorUrl.
        Flowbiz.initialize(FlowbizConfig(appId: "77777", debug: true))
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
