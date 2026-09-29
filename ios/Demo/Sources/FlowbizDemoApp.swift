import SwiftUI
import FlowbizOnsite

/// Fake-store demo over the production wiring, mirroring the Android demo
/// 1:1. Failed POSTs are harmless: events wait in the durable queue and retry
/// with backoff. os_log category `FlowbizOnsite`.
@main
struct FlowbizDemoApp: App {

    @StateObject private var store = DemoStore()

    init() {
        // Initialize once, at launch.
        #if DEBUG
        let collectorUrl = "https://collector.stg.mbzlabs.me"
        #else
        let collectorUrl = "https://collector.mailbiz.one"
        #endif
        Flowbiz.initialize(FlowbizConfig(
            appId: "77777",
            baseUri: "https://www.belamodastore.com.br",
            collectorUrl: collectorUrl,
            debug: true,
            recoveryUrl: "https://www.belamodastore.com.br/carrinho" // where recovery links land (Universal Link domain)
        ))
    }

    var body: some Scene {
        WindowGroup {
            ProductListView()
                .environmentObject(store)
                .onOpenURL { url in
                    // Forward every incoming link, recovery or not: handleLink
                    // also captures its UTMs.
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
